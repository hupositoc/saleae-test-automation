# SaleaeGuard

Saleae Logic 2 로깅 감시기 — **지금 로깅 중인지 확인하고, 멈춰 있으면 다시 시작**합니다.

**대상 고장**: Burst를 맞으면 Saleae가 USB 리셋을 먹고 PC에서 **순간적으로** 떨어졌다 붙으면서 캡처가 죽는 증상.

**현장 설정**: 디지털 채널 `0,1,2,3,4` (5채널), `5 MS/s`. 기본값으로 반영돼 있습니다.

---

## 왜 기존 방식(graphio.log + `r` 키)을 버렸나

전부 현장 실측입니다.

| 기존 방식 | 실측 결과 |
|---|---|
| `graphio.log`의 `start/stop capture` 파싱 | **4KiB 블록 버퍼링.** flush 지연 **45~77초** 측정. 디스크의 모든 로그 파일 크기가 4096의 배수 = 마지막 4095바이트는 **영구 미기록** |
| `stop capture`로 장애 판정 | 전체 1244건 중 실제 장애는 5건. **99.6%가 정상 정지** — 구분 불가 |
| `r` 키로 복구 | `r`은 `ToggleRecording`(Start/**Stop**). 이미 캡처 중이면 **정상 수집을 죽임** |
| `AppActivate($pid)` | **True를 반환하고도** 포커스가 다른 프로세스(msedge)에 있었음 |
| `Get-PnpDevice -PresentOnly` | 호출당 **약 4.4초**. 게다가 **비활성(Code 22) 장치도 "present"로 보고** |

Burst는 순간 단선입니다. 4.4초 폴링과 45초 로그 지연으로는 **애초에 볼 수가 없습니다.**

Automation API는 `get_devices()` **3ms**, 실물/시뮬레이션 **명시 구분**, `StartCapture`/`StopCapture` **분리**(토글 아님).

---

## 3중 감지 구조

USB 리셋 뒤 Logic이 두 가지 상태 중 하나가 될 수 있어서, 서로 독립된 층을 겹쳤습니다.

**Layer A — 정상상태 프로브 (`--check`, 기본 5초)**

> 녹화 중인 장치에 `StartCapture`를 걸면 Logic이 `Cannot switch sessions while recording`으로 **거부**합니다. 그 거부가 곧 "로깅 살아있음"의 증거이고, 거부되지 않으면 그 호출이 **그대로 복구**가 됩니다. 점검과 복구가 한 호출입니다.

**Layer B — USB 존재 추적 (`--poll`, 기본 0.25초) ← Burst 대응의 핵심**

Logic이 단선 후에도 세션을 "recording"으로 붙들고 있으면 Layer A는 **거짓 정상**을 냅니다. 그래서 USB 존재를 **독립적으로** 추적하고, 한 번이라도 사라진 것이 관측되면 프로브 결과와 **무관하게** 강제 재시작합니다. `get_devices()`가 3ms라 0.25초 폴링이 부담 없습니다.

**Layer C — 주기적 재순환 (`--rotate-seconds`, 기본 off)**

혹시 모를 좀비 세션의 수명 상한. 켜면 그 주기마다 캡처를 갈아엎습니다. 대신 매번 짧은 공백이 생깁니다.

폴링 핫패스에는 PowerShell 호출이 **없습니다**(호출당 200~400ms). gRPC 채널이 끊기는 것 자체가 Logic이 죽었다는 신호입니다.

### 좀비 세션 해소 (실측으로 잡은 버그)

테스트 중 Layer B가 실제로 발동했는데 **복구가 15번 연속 실패**했습니다.

```
*** USB RESTORED after 8.07s ***
hard restart requested (USB drop #1, outage 8.07s)
attempt 1..15: Logic still claims 'recording' - clearing.
hard restart FAILED after 15 attempts.
```

원인: 단선 뒤 Logic이 세션을 "recording"으로 붙들고 있는데, **와치독은 그 캡처의 핸들을 갖고 있지 않아** 내려놓을 방법이 없었습니다. 자기 핸들만 버려서는 영원히 풀리지 않습니다.

해결: `capture_id`를 직접 훑어 `StopCapture`로 정리합니다. 존재하지 않는 id는 무해하게 실패하므로 짧은 스캔이 안전합니다. 재현 검증 결과입니다.

```
BEFORE : Cannot switch sessions while recording
       -> cleared orphan session capture_id=6
AFTER  : started id=7   [FIX CONFIRMED]
```

### 기동 시 오탐 방지 (실측으로 잡은 버그)

Logic은 기동 후 장치 열거까지 몇 초가 걸립니다. 그 공백을 단선으로 오인해 기동하자마자 `USB DROP #1`을 찍는 문제가 있었습니다. 이제 장치를 **한 번 본 뒤에야** 단선 감지를 무장합니다.

```
device detected - drop detection armed.
```

---

## 설치 (PC마다 1회)

1. **Python 3.8 이상** 설치 (설치 시 *Add python.exe to PATH* 체크)
2. `SETUP.bat` 더블클릭 — venv 생성 + `logic2-automation` 설치

**인터넷이 없는 PC라면**, 연결된 PC에서 미리 받아둡니다.

```
pip download logic2-automation -d wheels
```

`wheels` 폴더를 스크립트 옆에 복사해두면 `SETUP.bat`이 자동으로 오프라인 설치합니다.

---

## 사용

| 파일 | 용도 |
|---|---|
| `CHECK_ONCE.bat` | 1회 점검. 종료코드 **0 = 로깅 정상**, 1 = 아님 |
| `START_GUARD.bat` | 상시 감시 + 자동 복구 (Ctrl+C로 중지) |

```bat
"venv\Scripts\python.exe" saleae_guard.py --channels 0,1,2,3,4 --rate 5000000 --poll 0.25 --check 5
```

주요 옵션: `--poll 0.25` · `--check 5` · `--rotate-seconds 0` · `--port 10430` · `--once`

로그는 `logs\saleae_guard_<날짜시각>.log`에 쌓입니다. USB 단선은 이렇게 남습니다.

```
*** USB DROP #3 - Saleae disappeared ***
*** USB RESTORED after 1.85s ***
hard restart requested (USB drop #3, outage 1.85s)
capture STARTED (id=7, device=DeviceType.LOGIC_16 B4045E72363CE3C7)
```

종료 시 누적 단선 횟수를 출력하므로, Burst 시험 한 세션에서 **몇 번 끊겼는지**가 그대로 집계됩니다.

---

## 검증된 동작 (실측)

**5채널 @ 5MS/s 캡처** — `start_capture` 0.239초, 6초 연속 수집 후 정상 정지 확인.

**장애 — Logic 프로세스 강제 종료**

```
11:10:46.879  kill
11:10:49.013  API channel lost (_InactiveRpcError) - checking Logic.
11:10:49.561  Logic is DOWN - relaunching.
11:10:53.827  reconnected to the Automation API.
11:10:56.801  capture STARTED (id=1)
11:10:56.851  OK - logging is running.        <- 총 약 10초 완전 복구
```

**장애 — Logic은 살아있고 캡처만 정지** (외부에서 StopCapture)

```
10:36:08      StopCapture
10:36:08.787  capture STARTED (id=2)          <- 1초 미만 복구
```

**성능**

| 항목 | 실측 |
|---|---|
| `get_devices()` | 0.003초 (`Get-PnpDevice` 4.4초 대비 ~1500배) |
| `start_capture()` | 0.14 ~ 0.24초 |
| `stop()` | 0.07초 |
| 와치독 CPU | 84초 구동에 CPU 2.88초 ≒ **1코어의 약 3.4%** (`--poll 0.25` 기준) |

CPU가 부담되면 `--poll 0.5`로 낮춰도 USB 재열거는 보통 1초 이상이라 놓치지 않습니다.

---

## ⚠ 투입 전 반드시 할 것 — 실물 단선 테스트

**Burst 경로(Layer B)는 실제 케이블 분리로 검증하지 못했습니다.** 소프트웨어로 캡처 중 USB 리셋을 강제할 방법이 없었습니다.

- `Disable-PnpDevice` → 캡처가 살아있는 동안 장치를 점유 중이라 **실패** (반복 확인)
- `pnputil /restart-device` → `rc=3010`(재부팅 필요)로 **실제 리셋이 일어나지 않음**. presence가 0이 된 적 없음
- 부모 USB 3.0 루트 허브 리셋 → 같은 허브에 **HID 입력 장치·블루투스·대용량 저장 장치**가 물려 있어 **하지 않음**

단, 단선 감지(DROP/RESTORED 로깅)와 좀비 세션 해소는 우발적으로 실제 발동해 **로그로 확인**됐습니다. 검증 안 된 것은 "실제 Burst 단선의 타이밍에서도 이 흐름이 그대로 도는가" 입니다.

그래서 **10초짜리 수동 검증**을 꼭 한 번 해주세요.

1. `START_GUARD.bat` 실행 → `OK - logging is running.` 확인
2. Saleae USB 케이블을 **뽑는다**
3. 로그에 `*** USB DROP #1 - Saleae disappeared ***` 가 뜨는지 확인
4. 다시 **꽂는다**
5. `*** USB RESTORED after N.NNs ***` → `capture STARTED` → `OK - logging is running.` 확인

3번이 안 뜨면 `--poll`을 더 줄이고, 5번에서 `Logic still claims 'recording'`이 반복되면 `--rotate-seconds 30`을 켜서 알려주세요. 그 로그가 있으면 Layer B를 정확히 맞출 수 있습니다.

---

## 다른 PC 이식성

머신 고유값을 **하드코딩하지 않습니다**.

- `logic.exe` — PATH → 레지스트리 Uninstall 키 → `%ProgramFiles%` 순으로 자동 탐색
- 설정 — `%APPDATA%\Logic\config.json`
- **USB VID/PID 없음** — 장치는 API가 `is_simulation=False`로 직접 골라줍니다
  (참고: 기존 스크립트는 `PID_1006` 고정이었으나 현장 장비는 `PID_1001`(Logic16)이라 영원히 DISCONNECT 판정이었습니다)
- 배치 파일은 ASCII 전용 — PS 5.1의 ANSI/UTF-8 BOM 인코딩 문제를 피합니다

---

## 자동으로 변경되는 설정

Automation API는 기본이 꺼져 있어, 최초 실행 시 자동으로 켭니다.

```
%APPDATA%\Logic\config.json  →  "automationServerEnabled": true
```

원본은 `config.json.saleaeguard.bak`으로 백업됩니다. 변경 후 Logic이 한 번 재시작돼야 포트 `10430`이 열립니다(스크립트가 알아서 처리).

---

## Kvaser / CanKing

이 도구는 **Saleae 전용**입니다. 기존 스크립트의 Kvaser heartbeat 감시는 별개 문제로 남아 있습니다.

- CanKing은 stdout에 heartbeat를 쓰지 않습니다
- 실제 데이터는 `defaultLogFilesFolder`(기본 `~\Documents`)의 Message Logger 파일이며,
  형식은 `0.1099  1  731  Rx  1  05  99` 입니다
- 기존 정규식 `Heartbeat OK. ID=0x731, State=Operational, Count=(\d+)`는 **어떤 실제 로그와도 일치하지 않습니다**
