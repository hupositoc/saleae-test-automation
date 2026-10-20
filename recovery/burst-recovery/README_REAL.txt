BurstRecovery ActiveRecovery - REAL USB / Count Reset

- 실제 Saleae/Kvaser USB를 Get-PnpDevice -PresentOnly 로 감지합니다.
- VID/PID:
  Saleae: USB\VID_21A9&PID_1006\
  Kvaser: USB\VID_0BFD&PID_0018\
- USB 복구는 실제 pnputil /scan-devices, /restart-device,
  필요 시 Disable-PnpDevice -> Enable-PnpDevice 를 사용합니다.
- 관리자 권한이 필요하며 START_REAL.bat 실행 시 UAC를 요청합니다.

유지된 최신 로직:
- Saleae graphio.log start capture / stop capture DATA 감시
- Saleae USB가 끊겼으면 DATA=COLLECTING이어도 복구 후 R 강제
- R 이후 새 start capture 확인 시 복구 성공
- Kvaser Heartbeat ID=0x731 / State=Operational / Count 증가 감시
- Kvaser 장애 시 F12, 복구 후 F9
- 복구 10초 카운트 중 다른 USB가 추가로 끊기면
  해당 장치도 복구하고 10초 카운트를 다시 시작
- Stage 1 실패 시 Stage 2, 이후에도 실패하면 RECOVERY FAILED

실행:
START_REAL.bat

로그:
C:\BurstRecovery\Logs\
