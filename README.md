# Saleae Test Automation | 시험 데이터 수집·복구 도구

시험 중 계측 장치 연결이 끊기거나 캡처가 중단되면 관측 데이터에 공백이 생긴다. 수집 제어와 장애 감시·복구를 별도 도구로 구성한 프로젝트다.

## 기술과 구성

Python · PySide6 · Saleae Automation API · PowerShell

```text
sampling-assistant/: 수집 제어 GUI
recovery/saleae-guard/: Automation API 기반 캡처 감시
recovery/burst-recovery/: USB 복구를 시도하는 이전 PowerShell 구현
```

## 엔지니어링 관점

수집 상태 판정, API 오류와 정상 동작의 구분, USB 단절 후 세션 복구, 로그 기반 원인 분석. README에 기록된 현장 수치는 기존 문서의 주장으로, 이번 준비 과정에서 재측정하지 않았다.

## AI를 활용한 개발 방식

이 프로젝트는 AI 개발 도구를 활용한 문제 해결 포트폴리오의 일부다. AI가 코드를 작성했다는 사실보다 문제 정의, 기술 선택, 결과 검토, 실패 원인 분석과 검증 근거를 중심으로 설명한다. 원본 개발 대화 전체는 확인하지 못했으므로 파일별 수작업·AI 작성 비율이나 사용 모델은 추정하지 않는다.

## 시작하기

설치: `python -m pip install -r requirements.txt`

- 수집 GUI: `python sampling-assistant/app.py`
- 감시기 옵션 확인: `python recovery/saleae-guard/saleae_guard.py --help`
- 이전 PowerShell 복구기는 관리자 권한과 장치 설정 검토 후 사용한다.
- 기본 출력 경로는 현재 사용자의 홈 폴더 아래 `SaleaeClockMonitor`다.

## 실행과 현재 상태

Logic 2 Automation Server와 실제 장치가 필요하다. USB 재시작·키 입력 자동화는 시스템 상태를 바꾸므로 격리된 시험 환경에서 검증한다. 하드웨어 동작·복구 성공률은 이번에 검증하지 않았다.

이번 공개 준비에서는 원본의 선별 복사와 정적 점검을 수행했다. 지원 도구·장비가 없는 환경에서 실행 성공, 운영 성과, 모델 정확도를 새로 확인한 것으로 주장하지 않는다. 상세 검증 결과는 `VALIDATION.md`에 기록한다.

## 출처·공개 범위

원본 작업 폴더에서 소스를 선별한 공개 준비본이다. 로그·자격증명·로컬 SDK 경로·실제 업무 데이터·실행 바이너리는 제외했다. 기존 저작권 고지와 제3자 라이선스는 유지한다. 원본 파일의 고지와 의존성 이용 조건이 적용되며, 이 저장소의 문서가 새 라이선스를 부여하지 않는다.
