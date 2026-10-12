// 账号 / 同步 / 媒体 / 导出端点的组装与鉴权。
//
// 设计取舍：
//   - 这些端点与 api.go 的 AI 端点分开组装：前者按"登录令牌 → userID"隔离数据，
//     后者是服务级静态令牌 + 无状态转换；混在一个 Server 上会让鉴权语义变得含糊。
//   - 依赖全部是接口，测试里注入 store.Memory / media.MemoryCatalog / syncsvc.Service
//     就能真跑，不需要数据库，也不需要网络。
//   - userID **只从令牌取**。请求结构体里根本没有 user_id 字段，而 httpx.DecodeJSON
//     拒绝未知字段，所以客户端就算塞 user_id，得到的也是 400，而不是写到别人名下。
package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/authn"
	"github.com/jolaaa999/DayCue/services/api/internal/httpx"
	"github.com/jolaaa999/DayCue/services/api/internal/media"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
	"github.com/jolaaa999/DayCue/services/api/internal/syncsvc"
)

// TokenIssuer 抽象令牌的签发与校验；authn.Issuer 满足它。
type TokenIssuer interface {
	Issue(userID string, ttl time.Duration) (string, error)
	Verify(token string) (string, error)
}

// SyncService 抽象同步用例；*syncsvc.Service 满足它。
//
// 用接口而不是直接依赖 *syncsvc.Service：handler 因此可以注入假实现来验证错误映射
// （例如拉取失败必须变成 500，而不是被当成"没有变更"返回空列表）。
type SyncService interface {
	Push(ctx context.Context, userID string, items []syncsvc.PushItem) ([]syncsvc.PushResult, error)
	Pull(ctx context.Context, userID, cursor string, limit int) (syncsvc.PullResult, error)
	Export(ctx context.Context, userID string) (store.ExportBundle, error)
	Purge(ctx context.Context, userID string) error
}

// 端点级上限：目的是保护服务端，而不是产品约束。
// 单个请求能触发的写入量必须有上限，否则一次请求就能长时间占用连接与事务。
const (
	defaultTokenTTL       = 30 * 24 * time.Hour
	defaultRequestTimeout = 30 * time.Second
	defaultMaxUploadBytes = 25 << 20
	maxPushItems          = 500
	maxPullLimit          = 500
	maxDevices            = 64
)

// AccountDeps 是账号 / 同步 / 媒体 / 导出端点所需的依赖。
type AccountDeps struct {
	Users  store.UserStore
	Sync   SyncService
	Media  media.Store
	Issuer TokenIssuer
	// Now 可注入，便于测试固定时间基准。
	Now func() time.Time
	// TokenTTL 为 0 时使用 30 天。
	TokenTTL time.Duration
	// RequestTimeout 为 0 时使用 30 秒。
	RequestTimeout time.Duration
	// MaxUploadBytes 为 0 时使用 25 MiB。
	MaxUploadBytes int64
}

// AccountHandler 承载账号域的全部 HTTP 处理。
type AccountHandler struct {
	deps AccountDeps
}

// NewAccountHandler 校验依赖并构造处理器。
//
// 缺依赖一律在装配期就报错，而不是等某个请求打进来才变成 500。
func NewAccountHandler(d AccountDeps) (*AccountHandler, error) {
	switch {
	case d.Users == nil:
		return nil, errors.New("api: Users 不能为空")
	case d.Sync == nil:
		return nil, errors.New("api: Sync 不能为空")
	case d.Media == nil:
		return nil, errors.New("api: Media 不能为空")
	case d.Issuer == nil:
		return nil, errors.New("api: Issuer 不能为空")
	}
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.TokenTTL <= 0 {
		d.TokenTTL = defaultTokenTTL
	}
	if d.RequestTimeout <= 0 {
		d.RequestTimeout = defaultRequestTimeout
	}
	if d.MaxUploadBytes <= 0 {
		d.MaxUploadBytes = defaultMaxUploadBytes
	}
	return &AccountHandler{deps: d}, nil
}

// Routes 返回账号域子路由。它自带中间件，可以单独挂载，也可以交给 NewRootHandler 合并。
func (h *AccountHandler) Routes() http.Handler {
	mux := http.NewServeMux()

	// 注册与登录是仅有的两个匿名端点：拿到令牌之前没有任何可隔离的数据。
	mux.HandleFunc("POST /v1/auth/register", h.handleRegister)
	mux.HandleFunc("POST /v1/auth/login", h.handleLogin)

	mux.Handle("GET /v1/devices", h.requireUser(h.handleListDevices))
	mux.Handle("POST /v1/devices", h.requireUser(h.handleUpsertDevice))
	mux.Handle("DELETE /v1/devices/{id}", h.requireUser(h.handleDeleteDevice))

	mux.Handle("POST /v1/sync/push", h.requireUser(h.handleSyncPush))
	mux.Handle("GET /v1/sync/pull", h.requireUser(h.handleSyncPull))

	mux.Handle("GET /v1/export", h.requireUser(h.handleExport))
	mux.Handle("DELETE /v1/account", h.requireUser(h.handleDeleteAccount))

	// 上传先鉴权再限体：反过来会让未认证的超大请求拿到 413（等于告诉外界请求被读过了）。
	mux.Handle("POST /v1/media", h.requireUserHandler(
		httpx.MaxBody(h.deps.MaxUploadBytes)(http.HandlerFunc(h.handleMediaUpload))))
	mux.Handle("GET /v1/media/{id}", h.requireUser(h.handleMediaDownload))
	mux.Handle("DELETE /v1/media/{id}", h.requireUser(h.handleMediaDelete))

	mux.HandleFunc("/", handleNotFound)

	return httpx.Chain(mux,
		httpx.Recover,
		httpx.WithRequestID,
		httpx.AccessLog,
		httpx.Timeout(h.deps.RequestTimeout),
	)
}

// NewRootHandler 把账号域端点与 api.go 的 AI 端点合并成一个根处理器。
//
// 挂载顺序不是"先注册优先"：Go 1.22 的 ServeMux 由**最具体的模式**胜出，
// 所以 /v1/devices 这类具体模式会先于 "/" 兜底命中，二者不会互相遮蔽。
// 主会话只需把 daycued 的 Handler 从 srv.Handler() 换成这里的返回值。
func NewRootHandler(s *Server, deps AccountDeps) (http.Handler, error) {
	if s == nil {
		return nil, errors.New("api: Server 不能为空")
	}
	accounts, err := NewAccountHandler(deps)
	if err != nil {
		return nil, err
	}
	accountRoutes := accounts.Routes()

	root := http.NewServeMux()
	for _, pattern := range []string{
		"/v1/auth/",
		"/v1/devices",
		"/v1/devices/",
		"/v1/sync/",
		"/v1/media",
		"/v1/media/",
		"/v1/export",
		"/v1/account",
	} {
		root.Handle(pattern, accountRoutes)
	}
	root.Handle("/", s.Handler())
	return root, nil
}

// ctxKeyUserID 是私有的上下文键类型：避免和其他包用同一个字符串键撞车。
type ctxKeyUserID struct{}

// UserIDFrom 取出已鉴权的 userID；第二个返回值为 false 说明该请求没走鉴权中间件。
func UserIDFrom(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(ctxKeyUserID{}).(string)
	return v, ok && v != ""
}

// requireUser 是账号域唯一的鉴权入口：解析 Bearer → 验签 → 确认账号仍然存在 → 注入 userID。
func (h *AccountHandler) requireUser(next http.HandlerFunc) http.Handler {
	return h.requireUserHandler(http.HandlerFunc(next))
}

// requireUserHandler 与 requireUser 等价，只是接收已经包装过的 http.Handler
// （例如 httpx.MaxBody 的结果），避免在调用点写类型转换。
func (h *AccountHandler) requireUserHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := authn.ParseBearer(r.Header.Get("Authorization"))
		if !ok {
			writeUnauthorized(w, r)
			return
		}
		userID, err := h.deps.Issuer.Verify(token)
		if err != nil {
			writeUnauthorized(w, r)
			return
		}
		// 令牌是自包含的、无法单独撤销，所以每次请求都要确认账号仍然存在：
		// 否则删号之后旧令牌还能继续往里写数据。
		if _, err := h.deps.Users.UserByID(r.Context(), userID); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				writeUnauthorized(w, r)
				return
			}
			writeInternal(w, r, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKeyUserID{}, userID)))
	})
}

// writeUnauthorized 统一 401 文案：不区分"没有令牌""令牌坏""账号已删除"，
// 免得把"这个账号是否存在"泄漏出去（也与 authn 包的设计保持一致）。
func writeUnauthorized(w http.ResponseWriter, r *http.Request) {
	httpx.WriteError(w, r, httpx.CodeUnauthorized, "缺少或无效的访问令牌。")
}

// writeInternal 记录真实原因，只向客户端下发笼统提示。
func writeInternal(w http.ResponseWriter, r *http.Request, err error) {
	slog.Error("账号接口内部错误",
		"trace_id", httpx.RequestID(r), "path", r.URL.Path, "reason", err.Error())
	httpx.WriteError(w, r, httpx.CodeInternal, "服务内部错误，请稍后重试。")
}

// writeDecodeError 把请求体解析失败映射成 400 / 413。
// 解码器拒绝未知字段，所以"请求里带 user_id"也会走到这里。
func writeDecodeError(w http.ResponseWriter, r *http.Request, err error) {
	if httpx.IsBodyTooLarge(err) {
		httpx.WriteError(w, r, httpx.CodePayloadTooLarge, "请求内容过大。")
		return
	}
	httpx.WriteError(w, r, httpx.CodeInvalidRequest, "请求体不是合法 JSON，或包含契约之外的字段。")
}

// now 统一时间来源，测试里可固定。
func (h *AccountHandler) now() time.Time { return h.deps.Now() }

// newOpaqueID 生成带前缀的随机标识；前缀让日志里一眼能看出是哪种对象。
func newOpaqueID(prefix string) string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// 随机数不可用属于灾难级故障：宁可 panic（由 Recover 兜成 500），
		// 也绝不能在这种时候生成可预测的 ID。
		panic("api: 生成随机 ID 失败: " + err.Error())
	}
	return prefix + hex.EncodeToString(b[:])
}

// validOpaqueID 校验客户端提供的标识：只允许字母、数字、下划线与连字符，长度受限。
// 目的是不让任意字符串（甚至路径片段）进入主键与日志。
func validOpaqueID(id string) bool {
	if len(id) < 8 || len(id) > 64 {
		return false
	}
	for _, c := range id {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_', c == '-':
		default:
			return false
		}
	}
	return true
}
