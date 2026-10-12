// Command daycued 是 DayCue 的最小后端服务。
//
// 只有本地/受控测试用途：不落库、不管账号，凭据全部来自环境变量。
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	// 内嵌 IANA 时区库：服务端必须能在任何主机上正确换算用户时区。
	_ "time/tzdata"

	"github.com/jolaaa999/DayCue/services/api/internal/api"
	"github.com/jolaaa999/DayCue/services/api/internal/config"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})))

	cfg := config.Load()
	if err := cfg.Validate(); err != nil {
		// 配置不安全时直接拒绝启动，避免把无认证的 AI 代理暴露出去。
		slog.Error("配置校验失败，拒绝启动", "error", err.Error())
		os.Exit(1)
	}

	srv := api.New(cfg)

	// 云同步是可选能力：未配置数据库时这里返回 nil，服务只提供 AI 端点。
	// 配置了却无法初始化（缺驱动等）则拒绝启动，避免"以为在同步其实没有"。
	cloudHandler, cloudStore, cloudNote, err := newCloudSyncHandler(cfg, srv)
	if err != nil {
		slog.Error("云同步初始化失败，拒绝启动", "error", err.Error())
		os.Exit(1)
	}

	// 主动推送与 HTTP 服务共用同一条生命周期：ctx 取消即随优雅关闭一起停。
	runCtx, cancelRun := context.WithCancel(context.Background())
	defer cancelRun()

	// 没有数据库时返回 nil runner 与一条说明（明确不启动）；凭据格式非法等才拒绝启动。
	pushRunner, pushInterval, pushNote, err := newProactiveRunner(cfg, cloudStore)
	if err != nil {
		slog.Error("主动推送初始化失败，拒绝启动", "error", err.Error())
		os.Exit(1)
	}

	// 候选生产者：把客户端同步上来的到期业务事件写进账本。
	// 没有数据库时同样返回 nil（明确不启动），而不是造一个永远查不到东西的生产者。
	pushProducer, err := newProactiveProducer(cfg, cloudStore)
	if err != nil {
		slog.Error("主动候选生产者初始化失败，拒绝启动", "error", err.Error())
		os.Exit(1)
	}
	rootHandler := http.Handler(srv.Handler())
	if cloudHandler != nil {
		rootHandler = cloudHandler
	}

	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           rootHandler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      90 * time.Second,
		IdleTimeout:       90 * time.Second,
	}

	slog.Info("daycued 启动",
		"addr", cfg.Addr,
		"env", cfg.Env,
		"fixture_mode", cfg.FixtureMode,
		"llm", providerState(srv.LLM != nil),
		"asr", providerState(srv.ASR != nil),
		"auth_required", cfg.AuthToken != "",
	)
	if cloudNote != "" {
		slog.Info(cloudNote)
	}
	if pushNote != "" {
		slog.Info(pushNote)
	}
	if pushRunner != nil {
		// 主动推送调度后台运行；单轮错误只记日志，不会拖垮 HTTP 服务。
		go pushRunner.Start(runCtx, pushInterval)
	}
	if pushProducer != nil {
		// 生产者与调度器共用同一个 runCtx，也共用同一个间隔。
		// 各跑各的循环：生产者只把事件变成账本行，本轮产出的行会在调度的下一次 tick 被认领。
		go pushProducer.Start(runCtx, pushInterval)
	}
	if cfg.FixtureMode {
		slog.Warn("模拟模式已开启：所有整理结果都是预设样例，不构成真实 AI 调用，界面上会标记为「模拟结果」")
	}
	if srv.LLM == nil {
		slog.Warn("未配置 DAYCUE_LLM_BASE_URL/MODEL，/v1/extractions 会返回 503")
	}

	errCh := make(chan error, 1)
	go func() {
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	select {
	case err := <-errCh:
		slog.Error("监听失败", "error", err.Error())
		os.Exit(1)
	case <-stop:
		slog.Info("收到退出信号，开始优雅关闭")
	}

	// 先停调度循环再关 HTTP：避免关闭过程中还在往推送通道发消息。
	cancelRun()

	ctx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	if err := httpSrv.Shutdown(ctx); err != nil {
		slog.Error("优雅关闭失败", "error", err.Error())
		os.Exit(1)
	}
	slog.Info("已退出")
}

func providerState(configured bool) string {
	if configured {
		return "configured"
	}
	return "absent"
}
