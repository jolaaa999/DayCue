package main

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jolaaa999/DayCue/services/api/internal/store"
)

// 执行方门控的单测。
//
// 这是「同一提醒不得两边同时安排」的唯一落点，所以两个方向都必须钉住：
// 客户端能投递时服务端让路、客户端没声称能投递时服务端接管。
// 少了任何一边，要么用户被重复打扰，要么提醒彻底没人发。

type fakeDevices struct {
	devices []store.Device
	err     error
}

func (f fakeDevices) DevicesByUser(_ context.Context, _ string) ([]store.Device, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.devices, nil
}

func device(id string, caps map[string]bool) store.Device {
	return store.Device{ID: id, UserID: "u1", Capabilities: caps}
}

func TestRouteOwnerYieldsWhenAnyDeviceCanNotify(t *testing.T) {
	owner := deviceRouteOwner{devices: fakeDevices{devices: []store.Device{
		device("d1", map[string]bool{}),
		device("d2", map[string]bool{"notifications": true}),
	}}}
	owned, reason, err := owner.ClientOwnsDelivery(context.Background(), "u1", time.Now())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	// 只要有一台能投递就让路：多设备用户里，任何一台本地响了都算已经投递过。
	if !owned {
		t.Fatalf("有设备能投递时应当让路，实际不让路（原因 %q）", reason)
	}
	if !strings.Contains(reason, "d2") {
		t.Fatalf("原因里应当点名是哪台设备，便于排查，实际 %q", reason)
	}
}

func TestRouteOwnerYieldsWhenCapabilityIsFalseOnOneAndTrueOnAnother(t *testing.T) {
	owner := deviceRouteOwner{devices: fakeDevices{devices: []store.Device{
		device("d1", map[string]bool{"notifications": false}),
		device("d2", map[string]bool{"notifications": true}),
	}}}
	owned, _, err := owner.ClientOwnsDelivery(context.Background(), "u1", time.Now())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if !owned {
		t.Fatal("只要有一台能投递就必须让路，不能因为另一台不能就两边都发")
	}
}

func TestRouteOwnerTakesOverWhenNoDeviceClaimsNotificationCapability(t *testing.T) {
	// 能力未知时客户端如实省略（iOS 的 DeviceCapabilities.unknown.wire 为空），
	// 所以「没有任何设备声称能投递」是真实会出现的状态，不是形式主义的分支。
	owner := deviceRouteOwner{devices: fakeDevices{devices: []store.Device{
		device("d1", map[string]bool{}),
		device("d2", map[string]bool{"speech_transcription": true}),
	}}}
	owned, reason, err := owner.ClientOwnsDelivery(context.Background(), "u1", time.Now())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if owned {
		t.Fatal("没有设备声称能投递时服务端应当接管，否则这条提醒没人发")
	}
	if !strings.Contains(reason, "没有上报") {
		t.Fatalf("原因应当说明为什么接管，实际 %q", reason)
	}
}

func TestRouteOwnerTakesOverWhenUserHasNoDevice(t *testing.T) {
	owner := deviceRouteOwner{devices: fakeDevices{}}
	owned, reason, err := owner.ClientOwnsDelivery(context.Background(), "u1", time.Now())
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if owned {
		t.Fatal("没有设备时服务端是唯一投递方")
	}
	if !strings.Contains(reason, "没有登记任何设备") {
		t.Fatalf("原因应当说明没有设备，实际 %q", reason)
	}
}

func TestRouteOwnerSurfacesLookupFailure(t *testing.T) {
	owner := deviceRouteOwner{devices: fakeDevices{err: errors.New("数据库不可用")}}
	_, _, err := owner.ClientOwnsDelivery(context.Background(), "u1", time.Now())
	if err == nil {
		t.Fatal("查询失败必须冒泡：生产者据此选择本轮不发，而不是当成「服务端接管」乱发")
	}
	if !strings.Contains(err.Error(), "数据库不可用") {
		t.Fatalf("应当保留原因，实际 %v", err)
	}
}

func TestProactiveRowIDIsUniqueAndPrefixed(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 64; i++ {
		id := newProactiveRowID()
		if !strings.HasPrefix(id, "pm_") {
			t.Fatalf("主键应带前缀便于识别，实际 %q", id)
		}
		if seen[id] {
			t.Fatalf("主键重复: %q", id)
		}
		seen[id] = true
	}
}
