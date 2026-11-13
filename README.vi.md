# Jira Notify

[![tests](../../actions/workflows/tests.yml/badge.svg)](../../actions/workflows/tests.yml)
[English](README.md)

Thông báo trên desktop Windows cho các ticket Jira cần bạn xử lý, để bạn không bỏ lỡ ticket nào:

- **To do**: ticket đang assign cho bạn và ở trạng thái **Open** hoặc **Reopened**, để bạn bắt tay làm.
- **Ready for Staging (RFS)**: ticket bạn từng làm đã lên **Ready for Staging**, để bạn xem có cần chuẩn bị script hay bước deploy nào trước khi ra production không.

Tool kiểm tra Jira vài phút một lần. Khi có ticket mới, nó hiện **một toast tổng**, còn không thì im lặng.

```
Jira Notify
Jira: 1 Open, 2 Ready for Staging
PROJ-128 (RFS) [Billing] Rounding error on invoices over 10,000...
PROJ-131 (Open) [Search] Add filter by warehouse  +1 more
[ To do (1) ]  [ Ready for Staging (2) ]  [ Ignore... ]  [ Dismiss ]
```

## Mục lục

- [Yêu cầu](#yêu-cầu)
- [Cài đặt](#cài-đặt)
- [Sử dụng hằng ngày](#sử-dụng-hằng-ngày)
- [Ticket nào được báo](#ticket-nào-được-báo)
- [Cấu hình](#cấu-hình)
- [Cơ chế hoạt động](#cơ-chế-hoạt-động)
- [Quyền riêng tư và bảo mật](#quyền-riêng-tư-và-bảo-mật)
- [Tự kiểm chứng](#tự-kiểm-chứng)
- [Xử lý sự cố](#xử-lý-sự-cố)
- [Phát triển](#phát-triển)

## Yêu cầu

- Windows 10 hoặc 11, có sẵn **Windows PowerShell 5.1**. Không cần cài thêm gì.
- **Jira Cloud** (`*.atlassian.net`) và **API token** của chính account Atlassian của bạn.
- Workflow Jira của bạn có các trạng thái muốn theo dõi. Mặc định là `Open`, `Reopened` và `Ready for Staging`, cả ba đều đổi được.

## Cài đặt

1. Lấy code về: chạy `git clone https://github.com/toaihoang/jira-notify.git`, hoặc chọn **Code > Download ZIP** rồi giải nén. Hãy để thư mục ở nguyên chỗ đó, vì scheduled task chạy script từ chính thư mục này.
2. Tạo API token tại <https://id.atlassian.com/manage-profile/security/api-tokens>.
3. Mở **PowerShell** trong thư mục đó và chạy:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install.ps1
   ```

4. Trả lời 3 câu hỏi: địa chỉ Jira (ví dụ `https://your-company.atlassian.net`), email Atlassian và token. Token không hiện ra khi bạn gõ.

Trình cài đặt sẽ:
- kiểm tra token với Jira, rồi lưu token đã mã hoá cho user Windows của bạn;
- ghi cài đặt vào `%LOCALAPPDATA%\JiraNotify\config.json`, với `SinceDate` là **ngày hôm nay**;
- tạo scheduled task `JiraNotify`, chạy mỗi 5 phút, khi đăng nhập, và 15 giây sau khi mở khoá màn hình;
- tạo shortcut **Check Jira now** trên Desktop và trong Start Menu;
- chạy kiểm tra lần đầu.

### Cập nhật, chuyển thư mục hoặc áp dụng lại cài đặt

Sau khi `git pull`, sau khi chuyển thư mục, hoặc sau khi đổi `IntervalMinutes`, chạy:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -TaskOnly
```

Lệnh này giữ nguyên token và cài đặt, chỉ tạo lại task, shortcut và các đăng ký.

> Nếu task được tạo lần đầu từ PowerShell **quyền Administrator**, Windows chỉ cho PowerShell quyền Administrator cập nhật nó. Trình cài đặt sẽ báo khi gặp trường hợp này.

### Gỡ cài đặt

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
```

Lệnh này xoá task, shortcut, hai đăng ký trong registry và thư mục `%LOCALAPPDATA%\JiraNotify` (token, cài đặt, danh sách ignore, log). Sau đó bạn xoá thư mục code.

## Sử dụng hằng ngày

### Toast

- **Tiêu đề**: số ticket theo từng trạng thái, ví dụ `Jira: 1 Open, 2 Ready for Staging`.
- **Nội dung**: các ticket mới, gồm mã, trạng thái và tên. Nếu có hơn 2 ticket mới, phần còn lại hiện thành `+N more`.
- **Bấm vào toast**: mở Jira với tất cả ticket trong danh sách.
- **To do (n)** / **Ready for Staging (n)**: mở Jira với riêng nhóm đó.
- **Ignore...**: mở [cửa sổ Ignore](#bỏ-qua-ticket-không-cần-script-production). Nút này chỉ hiện khi có ticket RFS.

Mỗi ticket chỉ được báo **một lần**, lúc nó vào nhóm, chứ không lặp lại mỗi vài phút. Toast bị lỡ vẫn nằm trong Notification Center (`Win + N`).

### Check Jira now

Double-click shortcut **Check Jira now** để xem tổng hiện tại ngay. Shortcut luôn trả lời. Nếu không có ticket nào, bạn sẽ thấy `Jira: nothing to do`.

### Nhắc buổi sáng

Các ngày thường lúc **08:30**, nếu vẫn còn ticket trong danh sách, bạn nhận toast `Morning reminder - Jira: ...`. Nếu lúc đó máy đang khoá hoặc chưa bật, tool nhắc ở lần kiểm tra đầu tiên sau đó. Mỗi ngày chỉ nhắc một lần.

### Bỏ qua ticket không cần script production

1. Bấm **Ignore...** trên toast. Cửa sổ liệt kê mọi ticket RFS kèm ngày vào RFS, mới nhất ở trên cùng.
2. **Double-click** một dòng để mở ticket trên Jira.
3. Tick các ticket không cần script rồi bấm **Save**.

Ticket đã bỏ qua:
- không còn xuất hiện trong toast mới, toast nhắc buổi sáng, các con số đếm và link Jira;
- chỉ bị ẩn **khi còn ở Ready for Staging**. Nếu bị trả về Open hoặc Reopened, bạn vẫn được báo.

Muốn được báo lại một ticket, bỏ tick, hoặc xoá dòng của nó trong `%LOCALAPPDATA%\JiraNotify\ignored.txt`.

### Khoá màn hình

Khi màn hình đang khoá, tool bỏ qua lượt kiểm tra nên không gọi Jira. Task chạy lại 15 giây sau khi bạn mở khoá. Không ticket nào bị sót, vì mỗi lần kiểm tra đều so với lần trước.

## Ticket nào được báo

| Nhóm | Điều kiện |
|---|---|
| To do | Đang assign cho bạn, ở một trong các `TodoStatuses`, và từ `SinceDate` trở đi ticket được tạo mới, được assign cho bạn, hoặc bị đưa về trạng thái đó. |
| Ready for Staging | **Từng** assign cho bạn, và được chuyển sang `StagingStatus` từ `SinceDate` trở đi. QA thường chuyển assignee khi ticket lên RFS, nên phải dùng điều kiện "từng assign". |

Ticket nằm ở các trạng thái này từ trước `SinceDate` sẽ bị bỏ qua, để ngày đầu cài bạn không bị ngập thông báo về ticket cũ.

## Cấu hình

Cài đặt nằm trong `%LOCALAPPDATA%\JiraNotify\config.json` (xem ví dụ ở [`config.example.json`](config.example.json)). Thay đổi có hiệu lực ở lần kiểm tra kế tiếp, trừ `IntervalMinutes`, cần chạy `Install.ps1 -TaskOnly`.

| Khoá | Mặc định | Ý nghĩa |
|---|---|---|
| `JiraBaseUrl` | hỏi khi cài | Địa chỉ Jira Cloud, dạng `https://...`, không có đường dẫn phía sau. |
| `TodoStatuses` | `["Open", "Reopened"]` | Các trạng thái tính là việc cần làm. |
| `StagingStatus` | `"Ready for Staging"` | Trạng thái sẵn sàng release, ghi đúng như trên Jira. |
| `SinceDate` | ngày cài | Chỉ tính thay đổi từ ngày này trở đi (`yyyy-MM-dd`). |
| `IntervalMinutes` | `5` | Bao nhiêu phút kiểm tra một lần (1 đến 1440). |
| `FailuresBeforeToast` | `3` | Số lần lỗi mạng liên tiếp trước khi hiện toast báo lỗi. |
| `MorningReminder` | `"08:30"` | Giờ nhắc mỗi ngày (`HH:mm`). Để `""` là tắt. |
| `MorningReminderWeekdaysOnly` | `true` | Không nhắc vào thứ Bảy và Chủ nhật. |
| `SkipWhenLocked` | `true` | Không kiểm tra khi màn hình đang khoá. |

Nếu `config.json` có chỗ sai, bạn nhận một toast ghi rõ lỗi, ví dụ `MorningReminder must look like 08:30`.

## Cơ chế hoạt động

Tool là PowerShell thuần: không có code biên dịch, không dùng module ngoài, không tải gì từ Internet. Nó chỉ liên lạc với site Jira của bạn.

```
 Task Scheduler (mỗi N phút / đăng nhập / mở khoá)    Shortcut "Check Jira now"
              |                                                |  (-Manual)
              v                                                v
 +------------------------------ src/Invoke-JiraCheck.ps1 -------------------------------+
 | 1. đọc config.json           4. GET /rest/api/3/myself      (token còn hợp lệ?)       |
 | 2. đang khoá máy? -> dừng    5. GET /rest/api/3/search/jql  (ticket của bạn)          |
 | 3. giải mã token (DPAPI)     6. bỏ ticket RFS đã ignore     7. so với lần trước       |
 |                              8. hiện toast nếu cần          9. lưu trạng thái, log    |
 +-----------------------------------------+---------------------------------------------+
                                           | các nút trên toast
             +-----------------------------+------------------------------+
             v                                                            v
  mở trang Jira trong trình duyệt                "Ignore..." -> src/Show-IgnoreWindow.ps1
  (không chạy script nào)                        (cửa sổ cục bộ, ghi ignored.txt)
```

### Một lần kiểm tra, từng bước

1. **Đọc và kiểm tra cài đặt.** Nếu có giá trị sai, lượt kiểm tra dừng lại và hiện toast ghi rõ lỗi.
2. **Bỏ qua nếu đang khoá màn hình.** Khi `LogonUI.exe` đang chạy trong phiên của bạn, lượt kiểm tra dừng ở đây và không gọi Jira.
3. **Giải mã token.** Chỉ user Windows của bạn làm được việc này.
4. **Xác thực token** bằng `GET /rest/api/3/myself`. Bước này quan trọng: với token sai, API tìm kiếm của Jira trả về *0 ticket* chứ không báo lỗi. Nếu thiếu bước này, token hết hạn sẽ trông như "không có việc gì".
5. **Lấy ticket** bằng `GET /rest/api/3/search/jql`, chỉ xin 3 trường `summary`, `status` và `statuscategorychangedate`. Với cài đặt mặc định, câu truy vấn là:

   ```
   (assignee = currentUser() AND status in ("Open", "Reopened")
     AND (created >= "<SinceDate> 00:00"
          OR assignee changed to currentUser() after "<SinceDate> 00:00"
          OR status changed to "Open" after "<SinceDate> 00:00"
          OR status changed to "Reopened" after "<SinceDate> 00:00"))
   OR
   (assignee was currentUser() AND status = "Ready for Staging"
     AND status changed to "Ready for Staging" after "<SinceDate> 00:00")
   ```

   Câu truy vấn dùng `"<ngày> 00:00"` chứ không chỉ `"<ngày>"`, vì `changed ... after "<ngày>"` sẽ loại hẳn cả ngày đó.
6. **Áp dụng danh sách ignore.** Các ticket RFS có trong danh sách bị loại ra. Ticket To do không bao giờ bị loại.
7. **So sánh với lần trước.** Tool ghi nhớ các cặp `MÃ|Trạng thái`. Một ticket được coi là *mới* nếu cặp này chưa có ở lần trước, nên ticket đổi trạng thái (In QA → Ready for Staging) cũng được tính là mới. Nhờ vậy mỗi ticket chỉ báo một lần, và không ticket nào bị sót khi máy tắt hay đang khoá.
8. **Quyết định có hiện toast không**:
   - **Check Jira now**: luôn hiện.
   - **Lần kiểm tra đầu tiên sau giờ nhắc**: hiện nếu danh sách không rỗng.
   - **Các trường hợp còn lại**: chỉ hiện khi có ticket mới.
9. **Lưu** trạng thái và cache ticket, rồi ghi log những gì đã xảy ra.

### Khi có lỗi

| Vấn đề | Cách tool xử lý |
|---|---|
| Token sai, hết hạn hoặc mất | Báo toast ngay, kèm nút **Create token**. |
| `config.json` sai | Báo toast ngay, ghi rõ giá trị sai. |
| Mất mạng hoặc VPN | Chỉ ghi log. Toast chỉ hiện sau `FailuresBeforeToast` lần lỗi liên tiếp. |
| Mọi trường hợp trên | Mỗi đợt lỗi chỉ hiện một toast, không lặp lại mỗi vài phút. Lần kiểm tra thành công kế tiếp tự xoá trạng thái lỗi. |

## Quyền riêng tư và bảo mật

### Mạng

- **Chỉ gửi request HTTPS tới `JiraBaseUrl`**: mỗi lượt kiểm tra có 2 lệnh `GET` chỉ đọc, cộng thêm 1 lệnh cho mỗi 100 ticket vượt thêm.
- **Không ghi gì lên Jira.** Tool không bao giờ tạo, sửa, chuyển trạng thái hay comment ticket.
- **Không gửi dữ liệu thống kê**, không dùng dịch vụ bên thứ ba, không tự cập nhật.
- **Không gửi gì khi màn hình đang khoá.**

### Dữ liệu lưu trên máy

Tất cả nằm trong `%LOCALAPPDATA%\JiraNotify\`:

| File | Nội dung |
|---|---|
| `credential.xml` | Email Atlassian và API token, mã hoá bằng Windows DPAPI. Chỉ user Windows của bạn trên máy này giải mã được. Copy file sang user hay máy khác cũng không dùng được. |
| `config.json` | Cài đặt của bạn. |
| `ignored.txt` | Các ticket RFS bạn chọn bỏ qua. |
| `seen-v2.json` | Các cặp `MÃ\|Trạng thái` của lần kiểm tra trước. |
| `last-issues.json` | Mã, trạng thái, tên và ngày vào RFS của các ticket lấy được lần gần nhất (cho cửa sổ Ignore). |
| `last-error.txt` | Số lần lỗi liên tiếp. File chỉ tồn tại khi đang có lỗi. |
| `last-reminder.txt` | Ngày nhắc buổi sáng gần nhất. |
| `jira-notify.log` | Những gì đã xảy ra và lúc nào. Log không bao giờ chứa token và tự được cắt khi vượt 1 MB. |
| `icon-v2.png`, `icon-v2.ico` | Icon chữ **J** xanh, được vẽ ngay trên máy. |

### Những gì thay đổi trong Windows

Mọi thay đổi chỉ áp dụng **cho user của bạn** và không cần quyền Administrator:

| Mục | Công dụng |
|---|---|
| Scheduled task `JiraNotify` | Chạy kiểm tra **dưới tên bạn**, quyền thường (limited), và chỉ khi bạn đang đăng nhập. Task chạy qua `conhost --headless` nên không có cửa sổ nào nháy lên. |
| `HKCU\Software\Classes\AppUserModelId\JiraNotify` | Tên và icon hiện trên toast. Mục này cũng thêm **Jira Notify** vào Settings > Notifications để bạn tắt tiếng được ở đó. |
| `HKCU\Software\Classes\jiranotify` | Cho phép nút **Ignore...** mở cửa sổ Ignore. |
| `Check Jira now.lnk` | Shortcut trên Desktop và trong Start Menu. |

`Install.ps1 -Uninstall` xoá mọi mục trong bảng trên và toàn bộ thư mục dữ liệu.

## Tự kiểm chứng

Bạn không cần tin lời README này, có thể tự kiểm tra:

- **Đọc code.** Mọi lệnh gọi mạng đều là `Invoke-RestMethod`. Tìm từ khoá này, bạn sẽ chỉ thấy `/myself` và `/search/jql`:

  ```powershell
  Select-String -Path .\Install.ps1, .\src\* -Pattern 'Invoke-RestMethod|Invoke-WebRequest'
  ```

- **Theo dõi tool chạy.** Đọc log, hoặc xem kết quả lần chạy gần nhất của task:

  ```powershell
  Get-Content "$env:LOCALAPPDATA\JiraNotify\jira-notify.log" -Tail 20
  Get-ScheduledTaskInfo -TaskName JiraNotify
  ```

- **Tự chạy một lần kiểm tra** và xem toast:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\src\Invoke-JiraCheck.ps1 -Manual
  ```

- **Đối chiếu với Jira.** Các nút trên toast mở đúng câu truy vấn đó trên Jira, nên bạn kiểm tra được các con số.
- **Thu hồi quyền bất cứ lúc nào** bằng cách xoá API token tại <https://id.atlassian.com/manage-profile/security/api-tokens>. Khi đó tool hiện toast "token invalid" và ngừng đọc Jira.

## Xử lý sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| Không thấy toast nào | Tắt Do Not Disturb hoặc Focus. Kiểm tra **Settings > System > Notifications > Jira Notify** đang bật. Xem log. |
| `API token expired or invalid` | Tạo token mới (toast có nút để tạo), rồi chạy `Install.ps1` **không có** `-TaskOnly`. |
| `cannot reach Jira` | Kiểm tra mạng hoặc VPN. Lỗi tự hết sau lần kiểm tra thành công kế tiếp. |
| `config.json has a problem` | Sửa giá trị được nêu trong toast. |
| Icon ở tiêu đề không phải chữ **J** xanh | Windows cache icon này. Đăng xuất rồi đăng nhập lại. |
| `Windows denied updating the 'JiraNotify' task` | Chạy lệnh bằng PowerShell quyền Administrator. |
| Không còn thông báo sau khi chuyển thư mục | Chạy `Install.ps1 -TaskOnly` từ chỗ mới. |
| Script bị chặn sau khi tải ZIP | Chạy `Get-ChildItem -Recurse \| Unblock-File` trong thư mục. |

## Phát triển

```
jira-notify/
├─ Install.ps1                 cài / -TaskOnly / -Uninstall
├─ src/
│  ├─ JiraNotify.psm1          code dùng chung: config, JQL, Jira API, trạng thái, định dạng, toast
│  ├─ Invoke-JiraCheck.ps1     một lần kiểm tra (scheduled task và "Check Jira now")
│  └─ Show-IgnoreWindow.ps1    cửa sổ Ignore (WinForms)
├─ tests/JiraNotify.Tests.ps1  Pester 5, chạy offline
├─ config.example.json
└─ .github/workflows/tests.yml chạy test trên Windows PowerShell 5.1
```

Chạy test:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck   # một lần
Invoke-Pester -Path .\tests -Output Detailed
```

Quy tắc khi đóng góp:
- **Tương thích Windows PowerShell 5.1.** Không dùng cú pháp chỉ có ở PowerShell 7 (`??`, `?.`, toán tử ba ngôi, `-Parallel`).
- **File `.ps1` / `.psm1` chỉ chứa ASCII.** Windows PowerShell 5.1 đọc file không có BOM theo ANSI, và có test kiểm tra điều này.
- **Giữ logic thuần.** Đặt phần quyết định vào các hàm nhận đầu vào qua tham số (xem test), còn các lệnh gọi Jira, file, registry và toast thì giữ thật mỏng.
- **Chỉ đọc Jira.** Không thêm endpoint nào làm thay đổi dữ liệu.
- **Ghi nhãn toast thử khi tự bắn bằng tay** (ví dụ `[TEST] ...`), vì toast thử trông giống hệt toast thật.

Code đã xử lý sẵn ba điểm dễ sai của Windows PowerShell 5.1:
- `ConvertFrom-Json` trả mảng JSON thành một object duy nhất, nên phải "mở" mảng trước khi dùng.
- Mảng 1 phần tử trả về từ hàm bị biến thành một `[pscustomobject]` đơn, không có `.Count`, nên phải bọc `@()` ở chỗ gọi.
- `[bool]"false"` cho kết quả `$true`.

## Giấy phép

[MIT](LICENSE)
