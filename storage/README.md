# Storage node — `sto` (Ubuntu 22.04 / Yoga)

**Reconstructed, untested on a new machine. DO NOT run on the existing Storage node.**

Actual evidence: `apt install -y lvm2 thin-provisioning-tools cinder-volume tgt crudini`; `/etc/cinder/cinder.conf` uses LVM backend `lvm`, driver `cinder.volume.drivers.lvm.LVMVolumeDriver`, VG `ubuntu-vg`, `target_protocol=iscsi`, `target_helper=tgtadm`, Controller Glance/Keystone; TGT includes `/var/lib/cinder/volumes/*`. Config has **no explicit** `lvm_type`, but runtime Cinder log selected thin provisioning automatically. Current Storage and scheduler were `enabled/up` on Controller.

**CRITICAL LVM SAFETY:** Original `/dev/nvme0n1p3` is an **OS PV**, with 450 GiB root LV and ~22.7 GiB thin pool in the **same** `ubuntu-vg`. The original `ubuntu-vg` has very little free space. Never `wipefs`, `pvcreate`, `vgremove`, `lvremove`, format or repartition this live drive. Script will **not** create a PV, VG, LV, thin pool, filesystem or LVM filter. You must inspect `lsblk`, `pvs`, `vgs`, `lvs` and prepare safe VG space **on a NEW TEST host** before running `cinder` stage. Avoid copying the original LVM device filter unless OS and storage PV paths genuinely match.

1. Configure management IP/hostname/hosts/DNS/NTP on a new Ubuntu 22.04 test Storage host.
2. Provision an appropriate test VG with the selected name separately; ensure it is not an unintended OS disk.
3. Copy `storage_yoga.env.example` to `~/storage_yoga.env`, `chmod 600 ~/storage_yoga.env`, edit private values. When using the supplied Controller script, CINDER_PASS = Controller SERVICE_PASS; CINDER_DB_PASS = Controller DB_PASS; RABBIT_PASS is shared with Controller.
4. Read script carefully, `bash -n storage_yoga.sh` and run each stage:

```bash
bash storage_yoga.sh preflight
# Set CONFIRM_FRESH_HOST=YES_FRESH_HOST in PRIVATE env only after inspecting the host
bash storage_yoga.sh base
bash storage_yoga.sh lvm-check
bash storage_yoga.sh cinder
bash storage_yoga.sh verify
```

5. On Controller run `openstack volume service list`. Expect `cinder-scheduler` and `sto@lvm` enabled/up. This does NOT prove volume creation or attach/detach. Verify those operations only with explicitly disposable test VM/volume and backups.

The script does not set `lvm_type` (original config omitted it). Cinder may create a thin pool automatically if conditions are met; this uses storage capacity and needs free VG extents. This is not a zero-risk or idempotent operation. The script also does not edit `/etc/lvm/lvm.conf`.


## 자동 재실행/중단 후 이어서 설치

해당 노드의 **신규 테스트 환경**에서 `.env` 설정 후 `bash storage_yoga.sh`를 인자 없이 실행하면 `base`부터 마지막 단계까지 순서대로 실행한다. 완료 마커는 `~/.local/state/openstack-yoga-storage/`에 보관된다. 재실행하면 마커+서비스 상태를 검사해 정상인 단계만 건너뛴다. 실패한 단계는 부분 적용된 파일과 서비스가 있을 수 있으므로 로그를 점검한 후 재실행한다. 이미 완료된 마커에 서비스 이상이 생기면 자동 덮어쓰기하지 않고 중단한다. DB, 디스크, 인증 설정의 임의 상태에 대한 완전 자동 복구는 지원하지 않는다.

## 2026-11-17 Notification amendment

New `notifications` stage enables `messagingv2` and `topics=notifications` for Cinder Volume in `/etc/cinder/cinder.conf`, then restarts `cinder-volume`. It does not alter `ubuntu-vg`, `tgt`, iSCSI target settings, or the OS disk. Earlier `cinder` completion markers remain valid. See `../docs/NOTIFICATIONS.md`. Only on a fresh disposable lab Storage host:

```bash
bash storage_yoga.sh notifications
```
