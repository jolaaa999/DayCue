// Package media 提供私有媒体存储。
//
// 设计取舍：
//   - 存储键**完全由服务端生成**（用户哈希 + 内容哈希），绝不拼接用户传入的 ID。
//     这是防止路径穿越的根本办法：客户端根本没有机会影响落盘路径。
//   - 目录按用户分片，读操作一律带上 userID —— 越权读取必须在存储层就被拒绝，
//     而不是指望上层每次都记得过滤。
//   - 内容类型采用白名单。未知类型直接拒绝，避免把可执行内容塞进对象存储。
package media

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var (
	// ErrNotFound 表示对象不存在**或不属于该用户**。两种情况故意不区分，
	// 免得把"这个 ID 存在但不是你的"泄漏给调用方。
	ErrNotFound = errors.New("media: 对象不存在")
	// ErrTooLarge 表示超过大小上限。
	ErrTooLarge = errors.New("media: 对象超过大小上限")
	// ErrUnsupportedType 表示内容类型不在白名单里。
	ErrUnsupportedType = errors.New("media: 不支持的内容类型")
	// ErrEmptyUser 表示缺少 userID。
	ErrEmptyUser = errors.New("media: userID 不能为空")
)

// 白名单：只允许这些前缀。音视频与图片是 DayCue 实际会产生的三类内容。
var allowedPrefixes = []string{"image/", "audio/", "video/", "text/plain", "application/pdf"}

// Object 是媒体对象的元数据。字节流本身不在这里。
type Object struct {
	ID          string
	UserID      string
	OwnerType   string
	OwnerID     string
	ContentType string
	ByteSize    int64
	SHA256      string
	StorageKey  string
	CreatedAt   time.Time
}

// Catalog 持久化元数据。与字节流分开，是为了以后换成对象存储时只换字节那半。
type Catalog interface {
	Insert(ctx context.Context, o Object) error
	ByID(ctx context.Context, userID, id string) (Object, error)
	ByOwner(ctx context.Context, userID, ownerType, ownerID string) ([]Object, error)
	Delete(ctx context.Context, userID, id string) error
	DeleteByOwner(ctx context.Context, userID, ownerType, ownerID string) ([]Object, error)
}

// Store 是媒体存储的对外接口。
type Store interface {
	Put(ctx context.Context, userID, ownerType, ownerID, contentType string, r io.Reader) (Object, error)
	Open(ctx context.Context, userID, id string) (io.ReadCloser, Object, error)
	Delete(ctx context.Context, userID, id string) error
	DeleteByOwner(ctx context.Context, userID, ownerType, ownerID string) error
	// DeleteByUser 清掉该用户的**全部**媒体。
	// 账号注销必须走这里：否则库里记录没了、磁盘上照片和录音还在，属于隐私泄漏。
	DeleteByUser(ctx context.Context, userID string) error
	List(ctx context.Context, userID, ownerType, ownerID string) ([]Object, error)
}

// UserWideCatalog 是 Catalog 的**可选**扩展能力。
//
// 之所以做成可选接口而不是直接加进 Catalog：Catalog 已有别的实现
// （PostgreSQL 版），强行加方法会让它编译不过。这里用类型断言探测能力，
// 不支持时返回明确错误，而不是假装删干净了。
type UserWideCatalog interface {
	DeleteAllForUser(ctx context.Context, userID string) ([]Object, error)
}

// FS 是落在本地文件系统上的实现。
type FS struct {
	root     string
	catalog  Catalog
	maxBytes int64
	now      func() time.Time
}

// NewFS 构造文件系统实现。maxBytes <= 0 时使用 25 MiB 默认值。
func NewFS(root string, catalog Catalog, maxBytes int64, now func() time.Time) (*FS, error) {
	if strings.TrimSpace(root) == "" {
		return nil, errors.New("media: root 不能为空")
	}
	if catalog == nil {
		return nil, errors.New("media: catalog 不能为空")
	}
	if now == nil {
		now = time.Now
	}
	if maxBytes <= 0 {
		maxBytes = 25 << 20
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("media: 解析 root 失败: %w", err)
	}
	if err := os.MkdirAll(abs, 0o700); err != nil {
		return nil, fmt.Errorf("media: 建根目录失败: %w", err)
	}
	return &FS{root: abs, catalog: catalog, maxBytes: maxBytes, now: now}, nil
}

// storageKeyFor 生成落盘相对路径。
//
// 键里只出现"用户哈希"和"内容哈希"两种十六进制串，**不含任何用户输入**，
// 所以 ../ 之类的穿越构造在这里没有任何作用面。
func storageKeyFor(userID, id, digest, contentType string) string {
	userPart := sha256.Sum256([]byte("daycue-user:" + userID))
	ext := extensionFor(contentType)
	return filepath.Join(
		hex.EncodeToString(userPart[:8]),
		digest[:2],
		id+ext,
	)
}

func extensionFor(contentType string) string {
	switch {
	case strings.HasPrefix(contentType, "image/png"):
		return ".png"
	case strings.HasPrefix(contentType, "image/jpeg"):
		return ".jpg"
	case strings.HasPrefix(contentType, "image/webp"):
		return ".webp"
	case strings.HasPrefix(contentType, "image/heic"):
		return ".heic"
	case strings.HasPrefix(contentType, "audio/m4a"), strings.HasPrefix(contentType, "audio/mp4"):
		return ".m4a"
	case strings.HasPrefix(contentType, "audio/wav"):
		return ".wav"
	case strings.HasPrefix(contentType, "video/"):
		return ".mp4"
	case strings.HasPrefix(contentType, "application/pdf"):
		return ".pdf"
	default:
		return ".bin"
	}
}

func typeAllowed(contentType string) bool {
	for _, p := range allowedPrefixes {
		if strings.HasPrefix(contentType, p) {
			return true
		}
	}
	return false
}

// Put 落盘一份内容并登记元数据。
//
// 先写临时文件再改名：中途失败不会留下半个对象被后续读到。
// 同时边写边算哈希，省掉一次全量重读。
func (f *FS) Put(ctx context.Context, userID, ownerType, ownerID, contentType string, r io.Reader) (Object, error) {
	if strings.TrimSpace(userID) == "" {
		return Object{}, ErrEmptyUser
	}
	contentType = strings.TrimSpace(strings.ToLower(contentType))
	if !typeAllowed(contentType) {
		return Object{}, fmt.Errorf("%w: %s", ErrUnsupportedType, contentType)
	}

	id, err := newID()
	if err != nil {
		return Object{}, err
	}

	// 先落到内存外的临时文件，拿到哈希后再决定最终位置。
	dir := filepath.Join(f.root, "tmp")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return Object{}, fmt.Errorf("media: 建临时目录失败: %w", err)
	}
	tmp, err := os.CreateTemp(dir, "put-*")
	if err != nil {
		return Object{}, fmt.Errorf("media: 建临时文件失败: %w", err)
	}
	tmpName := tmp.Name()
	// 任何提前返回都要清掉临时文件，否则失败会不断堆积垃圾。
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}()

	hasher := sha256.New()
	// 多留一个字节用来判断"是否超限"，比先统计再读更省事。
	limited := io.LimitReader(r, f.maxBytes+1)
	size, err := io.Copy(io.MultiWriter(tmp, hasher), limited)
	if err != nil {
		return Object{}, fmt.Errorf("media: 写入失败: %w", err)
	}
	if size > f.maxBytes {
		return Object{}, fmt.Errorf("%w: 上限 %d 字节", ErrTooLarge, f.maxBytes)
	}
	if err := tmp.Sync(); err != nil {
		return Object{}, fmt.Errorf("media: 刷盘失败: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return Object{}, fmt.Errorf("media: 关闭临时文件失败: %w", err)
	}

	digest := hex.EncodeToString(hasher.Sum(nil))
	key := storageKeyFor(userID, id, digest, contentType)
	finalPath := filepath.Join(f.root, key)

	// 再次确认目标路径仍在 root 之内。这是廉价的兜底断言：
	// 即使将来有人改了 storageKeyFor 引入了用户输入，这里也会拦住。
	if !withinRoot(f.root, finalPath) {
		return Object{}, errors.New("media: 目标路径越出存储根目录")
	}
	if err := os.MkdirAll(filepath.Dir(finalPath), 0o700); err != nil {
		return Object{}, fmt.Errorf("media: 建目录失败: %w", err)
	}
	if err := os.Rename(tmpName, finalPath); err != nil {
		return Object{}, fmt.Errorf("media: 落位失败: %w", err)
	}

	obj := Object{
		ID: id, UserID: userID, OwnerType: ownerType, OwnerID: ownerID,
		ContentType: contentType, ByteSize: size, SHA256: digest,
		StorageKey: key, CreatedAt: f.now().UTC(),
	}
	if err := f.catalog.Insert(ctx, obj); err != nil {
		// 元数据写不进去就把文件删掉，不留无人认领的孤儿对象。
		_ = os.Remove(finalPath)
		return Object{}, fmt.Errorf("media: 登记元数据失败: %w", err)
	}
	return obj, nil
}

// Open 以只读方式打开对象。meta 查找已按 userID 过滤，因此拿不到别人的对象。
func (f *FS) Open(ctx context.Context, userID, id string) (io.ReadCloser, Object, error) {
	if strings.TrimSpace(userID) == "" {
		return nil, Object{}, ErrEmptyUser
	}
	obj, err := f.catalog.ByID(ctx, userID, id)
	if err != nil {
		return nil, Object{}, ErrNotFound
	}
	path := filepath.Join(f.root, obj.StorageKey)
	if !withinRoot(f.root, path) {
		return nil, Object{}, ErrNotFound
	}
	fh, err := os.Open(path)
	if err != nil {
		return nil, Object{}, ErrNotFound
	}
	return fh, obj, nil
}

// Delete 删除对象与元数据。
func (f *FS) Delete(ctx context.Context, userID, id string) error {
	if strings.TrimSpace(userID) == "" {
		return ErrEmptyUser
	}
	obj, err := f.catalog.ByID(ctx, userID, id)
	if err != nil {
		return ErrNotFound
	}
	if err := f.catalog.Delete(ctx, userID, id); err != nil {
		return fmt.Errorf("media: 删元数据失败: %w", err)
	}
	path := filepath.Join(f.root, obj.StorageKey)
	if withinRoot(f.root, path) {
		// 文件已经不在也算成功：目标是"最终没有这个对象"。
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("media: 删文件失败: %w", err)
		}
	}
	return nil
}

// DeleteByOwner 删除某个实体名下的全部媒体。
//
// 记录被删除时必须连同媒体一起清掉，否则用户"删了记录"之后
// 照片和录音还留在磁盘上，属于隐私泄漏。
func (f *FS) DeleteByOwner(ctx context.Context, userID, ownerType, ownerID string) error {
	if strings.TrimSpace(userID) == "" {
		return ErrEmptyUser
	}
	objs, err := f.catalog.DeleteByOwner(ctx, userID, ownerType, ownerID)
	if err != nil {
		return fmt.Errorf("media: 按属主删除失败: %w", err)
	}
	for _, obj := range objs {
		path := filepath.Join(f.root, obj.StorageKey)
		if withinRoot(f.root, path) {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("media: 删文件失败: %w", err)
			}
		}
	}
	return nil
}

// DeleteByUser 删除该用户的全部媒体。
//
// 若底层 Catalog 不支持按用户枚举，返回明确错误而不是静默成功 ——
// "账号删了但文件还在"是安全问题，不能靠返回值含糊过去。
func (f *FS) DeleteByUser(ctx context.Context, userID string) error {
	if strings.TrimSpace(userID) == "" {
		return ErrEmptyUser
	}
	wide, ok := f.catalog.(UserWideCatalog)
	if !ok {
		return fmt.Errorf("%w: 当前元数据存储不支持按用户清理", ErrUnsupportedType)
	}
	objs, err := wide.DeleteAllForUser(ctx, userID)
	if err != nil {
		return fmt.Errorf("media: 按用户删除失败: %w", err)
	}
	for _, obj := range objs {
		path := filepath.Join(f.root, obj.StorageKey)
		if withinRoot(f.root, path) {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("media: 删文件失败: %w", err)
			}
		}
	}
	return nil
}

// List 列出某个属主名下的对象元数据。
func (f *FS) List(ctx context.Context, userID, ownerType, ownerID string) ([]Object, error) {
	if strings.TrimSpace(userID) == "" {
		return nil, ErrEmptyUser
	}
	return f.catalog.ByOwner(ctx, userID, ownerType, ownerID)
}

func withinRoot(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator))
}

func newID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("media: 生成 ID 失败: %w", err)
	}
	return "med_" + hex.EncodeToString(b), nil
}
