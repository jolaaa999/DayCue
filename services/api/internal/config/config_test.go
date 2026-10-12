package config

import (
	"testing"
	"time"
)

func TestIsLoopbackAddr(t *testing.T) {
	cases := map[string]bool{
		"127.0.0.1:8787": true,
		"localhost:8787": true,
		"[::1]:8787":     true,
		"0.0.0.0:8787":   false,
		":8787":          false,
		"192.168.1.5:87": false,
	}
	for addr, want := range cases {
		if got := IsLoopbackAddr(addr); got != want {
			t.Errorf("IsLoopbackAddr(%q) = %v, want %v", addr, got, want)
		}
	}
}

func TestValidateRejectsPublicBindWithoutToken(t *testing.T) {
	c := Config{Addr: "0.0.0.0:8787", Env: "development", MaxJSONBytes: 1024, MaxAudioBytes: 1024, RequestTimeout: time.Second}
	if err := c.Validate(); err == nil {
		t.Fatal("非环回监听且无令牌时必须拒绝启动")
	}
	c.AuthToken = "secret"
	if err := c.Validate(); err != nil {
		t.Fatalf("带令牌时应通过: %v", err)
	}
}

func TestValidateRejectsFixtureInProduction(t *testing.T) {
	c := Config{Addr: "127.0.0.1:8787", Env: "production", FixtureMode: true, MaxJSONBytes: 1024, MaxAudioBytes: 1024}
	if err := c.Validate(); err == nil {
		t.Fatal("生产环境开启模拟模式时必须拒绝启动")
	}
}
