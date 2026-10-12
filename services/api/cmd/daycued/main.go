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
	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Handler(),
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
