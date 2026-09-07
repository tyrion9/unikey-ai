# UnikeyAI

Bộ gõ tiếng Việt tuỳ biến từ mã nguồn mở **Unikey** (x-unikey 1.0.4). Unikey là bộ gõ đã được kiểm chứng qua hàng chục năm: **ổn định, nhẹ, đáng tin cậy** — dự án này ra đời với mong muốn **kế thừa đúng thuật toán gốc đó** (giữ **nguyên vẹn, không chỉnh sửa** phần xử lý Telex/VNI, bỏ dấu...) và đưa nó tới nhiều môi trường hơn, thay vì viết lại từ đầu. Bắt đầu từ macOS — nơi Unikey gốc chưa hỗ trợ — với phần tích hợp macOS viết mới hoàn toàn (có sự hỗ trợ của AI, Claude Code); Linux tiếp tục dùng đúng mã nguồn XIM/GTK gốc trong repo này.

> Phiên bản hiện tại: **v0.3** · macOS (13 trở lên, Apple Silicon + Intel) · Linux (qua mã nguồn XIM/GTK gốc)

## Nền tảng hỗ trợ

| Nền tảng | Trạng thái | Ghi chú |
|---|---|---|
| **macOS** | Đóng gói sẵn (`.dmg`), cài như app bình thường | Phần tích hợp mới, xem [Cài đặt nhanh](#cài-đặt-nhanh-dành-cho-người-dùng) bên dưới |
| **Linux** | Build từ mã nguồn (autotools) | Chính là bản Unikey gốc (XIM server + GTK input method module) — chưa đổi gì, xem [`INSTALL`](INSTALL) và [`doc/manual`](doc/manual) |

## Mục lục

- [Nền tảng hỗ trợ](#nền-tảng-hỗ-trợ)
- [Cài đặt nhanh trên macOS (dành cho người dùng)](#cài-đặt-nhanh-dành-cho-người-dùng)
- [Tính năng](#tính-năng)
- [Những gì đã thay đổi so với Unikey gốc](#những-gì-đã-thay-đổi-so-với-unikey-gốc)
- [Build từ mã nguồn](#build-từ-mã-nguồn)
- [Giấy phép](#giấy-phép)
- [Ghi công](#ghi-công)

## Cài đặt nhanh (dành cho người dùng)

Không cần biết lập trình, làm theo đúng các bước sau:

1. Vào mục **[Releases](../../releases)** của repo này, tải file **`UnikeyAI.dmg`** (bản mới nhất).
2. Mở file `.dmg` vừa tải, kéo icon **UnikeyAI** thả vào thư mục **Applications**.
3. Mở app lần đầu: macOS sẽ cảnh báo "không xác định được nhà phát triển" (vì app chưa mua chứng chỉ Apple) — vào **System Settings > Privacy & Security**, kéo xuống cuối, bấm **"Open Anyway"**. Hoặc chuột phải vào app > **Open**.
4. macOS sẽ xin quyền — vào **System Settings > Privacy & Security**:
   - Mục **Accessibility**: bật **UnikeyAI**.
   - Mục **Input Monitoring**: bật **UnikeyAI**.
5. Thoát app (menu trên thanh menu bar > "Thoát ứng dụng") rồi mở lại.
6. Xong! Icon chữ **V** xuất hiện trên thanh menu bar (góc trên phải màn hình) — gõ thử tiếng Việt bất kỳ đâu.

Bấm chữ **V/E** trên menu bar để mở bảng điều khiển, hoặc bấm tổ hợp phím **⌘ + ⇧ (Cmd+Shift)** để bật/tắt gõ tiếng Việt nhanh.

## Tính năng

- Gõ **Telex** và **VNI** — dùng đúng thuật toán bỏ dấu của Unikey gốc.
- Phím tắt **⌘⇧ (Cmd+Shift)** bật/tắt gõ tiếng Việt ở bất kỳ đâu trên máy.
- Bảng điều khiển riêng: bật/tắt gõ tiếng Việt, chọn kiểu gõ, bật/tắt khởi động cùng macOS, bật/tắt hiện bảng điều khiển khi mở app, nút ẩn giao diện.
- Tự sửa lỗi gõ dấu bị lặp chữ trên thanh địa chỉ Chrome/trình duyệt gốc Chromium (do gợi ý tự động điền của trình duyệt).
- Không cần cài X11/GTK như bản Linux gốc — chạy độc lập trên macOS.
- Đóng gói sẵn file `.dmg`, cài như mọi app macOS khác.

## Những gì đã thay đổi so với Unikey gốc

Dự án gốc [x-unikey 1.0.4](http://unikey.org) chỉ chạy trên Linux (XIM server + GTK Input Method module). Toàn bộ phần dưới đây là **mới**, nằm trong thư mục [`macos/`](macos/); thuật toán xử lý tiếng Việt trong [`src/`](src/) (bỏ dấu, nhận diện âm tiết...) giữ **nguyên vẹn** — chỉ 2 thay đổi nhỏ nêu bên dưới, không đụng tới thuật toán.

| Hạng mục | Chi tiết |
|---|---|
| **Build cho macOS** | Viết mới `macos/main.mm`: dùng `CGEventTap` (macOS) để bắt phím thay cho XIM/GTK (Linux), gọi thẳng hàm `UnikeyFilter()` gốc — không sửa thuật toán. |
| **Sửa lỗi biên dịch** | `src/ukengine/mactab.cpp`: 1 dòng `char*` → `const char*` để biên dịch được bằng clang hiện đại (code gốc viết cho gcc cũ trên Linux 2005). |
| **Bỏ ánh xạ `[`/`]`/`{`/`}` trong Telex** | `src/ukengine/inputproc.cpp` (`TelexMethodMapping`): bản Telex gốc dùng `[`→ơ, `]`→ư (và `{`/`}` cho Ơ/Ư) như một lối tắt thay cho `w`. Bỏ ánh xạ này vì người dùng UnikeyAI gõ dấu ngoặc vuông/nhọn thật (code, markdown...) rất thường xuyên — giờ `[` `]` `{` `}` luôn ra đúng ký tự đó; gõ ơ/ư/ă chỉ còn qua phím `w`. Chỉ áp dụng cho kiểu gõ Telex, không ảnh hưởng thuật toán bỏ dấu. |
| **Sửa lỗi Chrome address bar** | Phát hiện và loại bỏ vùng gợi ý tự động điền của Chrome (qua Accessibility API) trước khi xoá/gõ lại ký tự có dấu, tránh lỗi nhân đôi chữ (vd "ô" → "oô"). |
| **Giao diện (GUI)** | Icon trên thanh menu bar (chữ V/E), bảng điều khiển riêng: công tắc bật/tắt, chọn Telex/VNI, khởi động cùng macOS, hiện bảng khi khởi động, nút ẩn giao diện. |
| **Phím tắt hệ thống** | Tổ hợp **⌘⇧ (Cmd+Shift)** bật/tắt gõ tiếng Việt, nhận diện qua theo dõi trạng thái phím, không xung đột với các phím tắt khác của hệ thống. |
| **Icon ứng dụng** | Icon riêng (nền đỏ, sao vàng) được vẽ và đóng gói tự động lúc build, không cần thiết kế bằng tay. |
| **Ký & đóng gói** | Ký bằng chứng chỉ tự tạo cục bộ (ổn định qua các lần build, không mất quyền hệ thống); đóng gói `.dmg` cài đặt kiểu kéo-thả chuẩn macOS. |
| **Đổi tên & phiên bản** | Đổi tên ứng dụng thành **UnikeyAI**, đánh số phiên bản riêng cho nhánh macOS này (hiện tại: **v0.3**). |
| **Universal binary** | Build cho cả **Apple Silicon (arm64)** và **Intel (x86_64)** trong cùng 1 file `.app`. |

## Build từ mã nguồn

### macOS

Chỉ cần Terminal + Xcode Command Line Tools, không cần mở Xcode:

```bash
cd macos
./build.sh        # build ra UnikeyAI.app (universal: arm64 + x86_64)
open UnikeyAI.app # chạy thử — lần đầu cần cấp quyền như phần Cài đặt ở trên
./make_dmg.sh     # đóng gói thành UnikeyAI.dmg để phân phối
```

`build.sh` tự tìm chứng chỉ ký số cục bộ tên `VietTypeMacLocalDev`; nếu máy bạn chưa có, xem hướng dẫn tạo (1 lần duy nhất) trong **[`macos/README.md`](macos/README.md)** — có kèm lý do vì sao cần chứng chỉ này (để quyền Accessibility/Input Monitoring không bị macOS thu hồi mỗi lần build lại).

### Linux

Đây chính là bản Unikey gốc (XIM server + module GTK), build bằng autotools như mọi bản Unikey Linux khác — không có gì thay đổi:

```bash
./configure
make
sudo make install
```

Xem chi tiết ở [`INSTALL`](INSTALL) và [`doc/manual`](doc/manual).

## Giấy phép

Dự án kế thừa giấy phép từ Unikey gốc — mã nguồn gốc trong `src/` giữ nguyên giấy phép ghi ở đầu mỗi file:

- Phần lõi xử lý tiếng Việt (`src/ukengine`, `src/ukinterface`, `src/vnconv`, `src/byteio`): **GNU Lesser General Public License v2** (xem [`COPYING`](COPYING)).
- Các thành phần Linux gốc (`src/xim`, `src/gui`, `src/unikey-gtk`): **GNU General Public License v2**.

Phần macOS mới (thư mục `macos/`) được viết thêm và phát hành theo cùng tinh thần mã nguồn mở, kế thừa các giấy phép nêu trên tương ứng với phần lõi mà nó gọi tới.

## Ghi công

- **Phạm Kim Long** và nhóm phát triển Unikey gốc — tác giả thuật toán và mã nguồn `x-unikey` ([unikey.org](http://unikey.org)), xem thêm [`AUTHORS`](AUTHORS) và [`CREDITS`](CREDITS).
- Phần tích hợp macOS, giao diện và các bản sửa lỗi trong bản UnikeyAI này được viết với sự hỗ trợ của **Claude Code** (Anthropic).
