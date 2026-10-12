package media

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var base = time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)

func newStore(t *testing.T) *FS {
	t.Helper()
	dir := t.TempDir()
	s, err := NewFS(dir, NewMemoryCatalog(), 1<<20, func() time.Time { return base })
	if err != nil {
		t.Fatalf("构造存储失败: %v", err)
	}
	return s
}

func TestPutThenOpenRoundTrip(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()
	payload := []byte("这是一张白板照片的字节流")

	obj, err := s.Put(ctx, "u1", "capture", "c1", "image/png", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("写入失败: %v", err)
	}
	if obj.ByteSize != int64(len(payload)) {
		t.Fatalf("字节数应为 %d，实际 %d", len(payload), obj.ByteSize)
	}
	if len(obj.SHA256) != 64 {
		t.Fatalf("应记录 SHA-256，实际 %q", obj.SHA256)
	}

	rc, got, err := s.Open(ctx, "u1", obj.ID)
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("读取内容失败: %v", err)
	}
	if !bytes.Equal(data, payload) {
		t.Fatalf("内容不一致: %q", data)
	}
	if got.ContentType != "image/png" {
		t.Fatalf("内容类型应为 image/png，实际 %s", got.ContentType)
	}
}

func TestOtherUserCannotOpen(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()
	obj, _ := s.Put(ctx, "u1", "capture", "c1", "image/png", strings.NewReader("私有内容"))

	// 越权读取必须在存储层就被拒绝。
	if _, _, err := s.Open(ctx, "u2", obj.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("他人不应读到对象，实际 %v", err)
	}
	// 必须显式关闭：Windows 上未关闭的句柄会锁住文件，连测试目录都删不掉。
	rc, _, err := s.Open(ctx, "u1", obj.ID)
	if err != nil {
		t.Fatalf("本人应能读到，实际 %v", err)
	}
	rc.Close()
}

func TestOtherUserCannotDelete(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()
	obj, _ := s.Put(ctx, "u1", "capture", "c1", "image/png", strings.NewReader("x"))

	if err := s.Delete(ctx, "u2", obj.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("他人不应能删，实际 %v", err)
	}
	// u1 的对象必须仍然在。
	rc, _, err := s.Open(ctx, "u1", obj.ID)
	if err != nil {
		t.Fatalf("对象不应被他人删掉，实际 %v", err)
	}
	rc.Close()
}

func TestUnsupportedContentTypeRejected(t *testing.T) {
	s := newStore(t)
	for _, ct := range []string{"application/x-msdownload", "application/javascript", "text/html", ""} {
		if _, err := s.Put(context.Background(), "u1", "capture", "c1", ct, strings.NewReader("x")); !errors.Is(err, ErrUnsupportedType) {
			t.Errorf("内容类型 %q 应被拒绝，实际 %v", ct, err)
		}
	}
}

func TestOversizeRejectedAndNoFileLeftBehind(t *testing.T) {
	s := newStore(t)
	big := bytes.Repeat([]byte("a"), int(1<<20)+10)
	if _, err := s.Put(context.Background(), "u1", "capture", "c1", "image/png", bytes.NewReader(big)); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("超限应被拒绝，实际 %v", err)
	}

	// 失败不能留下垃圾文件（临时目录也要清干净）。
	var leftovers int
	_ = filepath.Walk(s.root, func(p string, info os.FileInfo, err error) error {
		if err == nil && info != nil && !info.IsDir() {
			leftovers++
		}
		return nil
	})
	if leftovers != 0 {
		t.Fatalf("失败后不应残留文件，实际 %d 个", leftovers)
	}
}

func TestStorageKeyNeverContainsUserInput(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()

	// 恶意 ownerID / userID 不能影响落盘路径。
	obj, err := s.Put(ctx, "../../etc", "../../../passwd", "c1", "image/png", strings.NewReader("x"))
	if err != nil {
		t.Fatalf("写入失败: %v", err)
	}
	if strings.Contains(obj.StorageKey, "..") {
		t.Fatalf("存储键不得包含 ..，实际 %s", obj.StorageKey)
	}
	full := filepath.Join(s.root, obj.StorageKey)
	if !withinRoot(s.root, full) {
		t.Fatalf("落盘路径越出根目录: %s", full)
	}
	// 文件确实在根目录之内。
	if _, err := os.Stat(full); err != nil {
		t.Fatalf("文件应存在于根目录内: %v", err)
	}
}

func TestDeleteByOwnerRemovesFilesFromDisk(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()

	o1, _ := s.Put(ctx, "u1", "capture", "c1", "image/png", strings.NewReader("one"))
	o2, _ := s.Put(ctx, "u1", "capture", "c1", "audio/m4a", strings.NewReader("two"))
	keep, _ := s.Put(ctx, "u1", "capture", "c2", "image/png", strings.NewReader("keep"))

	// 删除前先把落盘路径记下来：删完之后元数据就没了，
	// 再想核对"文件到底删没删"就无从查起。
	paths := map[string]string{o1.ID: o1.StorageKey, o2.ID: o2.StorageKey}

	if err := s.DeleteByOwner(ctx, "u1", "capture", "c1"); err != nil {
		t.Fatalf("按属主删除失败: %v", err)
	}

	// 删除记录时必须连媒体一起清掉，否则隐私数据留在磁盘上。
	for id, key := range paths {
		if _, _, err := s.Open(ctx, "u1", id); !errors.Is(err, ErrNotFound) {
			t.Errorf("对象 %s 应已被删除，实际 %v", id, err)
		}
		if _, err := os.Stat(filepath.Join(s.root, key)); err == nil {
			t.Errorf("对象 %s 的文件应已从磁盘删除: %s", id, key)
		}
	}
	rc, _, err := s.Open(ctx, "u1", keep.ID)
	if err != nil {
		t.Fatalf("其它记录的对象不应被牵连，实际 %v", err)
	}
	rc.Close()
}

func TestDeleteByUserRemovesEveryFileFromDisk(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()

	// 同一个用户、不同属主类型与不同记录，全部都要被清掉。
	a, _ := s.Put(ctx, "u1", "capture", "c1", "image/png", strings.NewReader("照片"))
	b, _ := s.Put(ctx, "u1", "note", "n1", "audio/m4a", strings.NewReader("录音"))
	c, _ := s.Put(ctx, "u1", "follow_up", "f1", "image/jpeg", strings.NewReader("截图"))
	other, _ := s.Put(ctx, "u2", "capture", "c1", "image/png", strings.NewReader("别人的"))

	paths := map[string]string{a.ID: a.StorageKey, b.ID: b.StorageKey, c.ID: c.StorageKey}

	if err := s.DeleteByUser(ctx, "u1"); err != nil {
		t.Fatalf("按用户删除失败: %v", err)
	}

	// 账号注销后磁盘上不能留下任何该用户的字节 —— 这是隐私要求，不是优化。
	for id, key := range paths {
		if _, _, err := s.Open(ctx, "u1", id); !errors.Is(err, ErrNotFound) {
			t.Errorf("对象 %s 元数据应已删除，实际 %v", id, err)
		}
		if _, err := os.Stat(filepath.Join(s.root, key)); err == nil {
			t.Errorf("对象 %s 的文件仍在磁盘上: %s", id, key)
		}
	}

	// 另一个用户必须毫发无伤。
	rc, _, err := s.Open(ctx, "u2", other.ID)
	if err != nil {
		t.Fatalf("其它用户的对象不应被牵连，实际 %v", err)
	}
	rc.Close()
}

func TestDeleteByUserRejectsEmptyUser(t *testing.T) {
	s := newStore(t)
	if err := s.DeleteByUser(context.Background(), "  "); !errors.Is(err, ErrEmptyUser) {
		t.Fatalf("空 userID 应被拒绝，实际 %v", err)
	}
}

func TestListScopedToOwnerAndUser(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()
	s.Put(ctx, "u1", "capture", "c1", "image/png", strings.NewReader("a"))
	s.Put(ctx, "u1", "capture", "c1", "image/jpeg", strings.NewReader("b"))
	s.Put(ctx, "u1", "capture", "c2", "image/png", strings.NewReader("c"))
	s.Put(ctx, "u2", "capture", "c1", "image/png", strings.NewReader("d"))

	got, err := s.List(ctx, "u1", "capture", "c1")
	if err != nil {
		t.Fatalf("列举失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("应为 2 个对象，实际 %d", len(got))
	}
	for _, o := range got {
		if o.UserID != "u1" || o.OwnerID != "c1" {
			t.Fatalf("列举结果串了用户或属主: %+v", o)
		}
	}
}

func TestEmptyUserRejected(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()
	if _, err := s.Put(ctx, "  ", "capture", "c1", "image/png", strings.NewReader("x")); !errors.Is(err, ErrEmptyUser) {
		t.Fatalf("空 userID 应被拒绝，实际 %v", err)
	}
	if _, _, err := s.Open(ctx, "", "x"); !errors.Is(err, ErrEmptyUser) {
		t.Fatalf("空 userID 应被拒绝，实际 %v", err)
	}
	if err := s.Delete(ctx, "", "x"); !errors.Is(err, ErrEmptyUser) {
		t.Fatalf("空 userID 应被拒绝，实际 %v", err)
	}
	if _, err := s.List(ctx, "", "capture", "c1"); !errors.Is(err, ErrEmptyUser) {
		t.Fatalf("空 userID 应被拒绝，实际 %v", err)
	}
}

func TestDeleteIsIdempotentlyNotFoundAfterFirst(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()
	obj, _ := s.Put(ctx, "u1", "capture", "c1", "image/png", strings.NewReader("x"))

	if err := s.Delete(ctx, "u1", obj.ID); err != nil {
		t.Fatalf("首次删除应成功: %v", err)
	}
	// 第二次返回 NotFound 而不是报"内部错误"：调用方可以安全重试。
	if err := s.Delete(ctx, "u1", obj.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("再次删除应返回 ErrNotFound，实际 %v", err)
	}
}
