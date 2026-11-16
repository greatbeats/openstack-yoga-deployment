# OpenStack Controller 재현 구축 가이드 (Ubuntu 22.04 / Yoga)

**문서 성격:** 캡스톤 프로젝트의 Controller(`con`) 구축 이력을 근거로 작성한 **신규 설치용 재구성 가이드**이다. **완전한 테스트 설치를 실행하여 성공을 검증한 산출물이 아니다.** `controller_yoga.sh`는 기본 실행 시 전체 단계를 자동으로 순차 실행하며 운영 중인 Controller에서 절대로 실행하지 않는다. 입력하는 명령은 이미 구축된 환경을 중복 생성하거나 서비스와 네트워크를 중단시킬 수 있다.

## 파일

- `controller_yoga.sh`: 재현용 Controller 전체 자동 구축(기본 실행) 및 개별 단계 명령. `bash -n`으로 문법만 점검했다.
- `controller_yoga.env.example`: 환경 변수 양식. 비밀번호는 `<ENTER_ADMIN_PASS>` 같은 영어 자리표시자로 표시되어 있으며, 실제 설치 전에 모두 수정해야 한다.
- 이 문서: 실제 기록과 새로 보완한 내용을 구분한 적용 순서, 검증 기준, 주의사항.

## 1. 구성과 실제 기록의 관계

| 항목 | 실제 원본 근거 | 재현용 조정 |
|---|---|---|
| Ubuntu 22.04, apt 직접 설치 | 2026-09-23 APT 기록 A001–A015 | 깨끗한 22.04에서 단계별 설치 |
| Chrony → MariaDB → RabbitMQ → Memcached | A001–A004 | 공통 인프라를 완성한 다음 Keystone 설치 |
| Keystone → Glance → Nova → Neutron → Horizon | A005–A009 | **Keystone → Glance → Placement → Nova → Neutron → Horizon**로 의존성 재정렬 |
| Placement | B027–B030, A013: 원래 Nova 뒤 보완 | Nova 전에 구축·인증 연결 |
| Cinder API/Scheduler | B058–B063, A015 | 별도 Storage 노드의 cinder-volume은 제외 |
| DB·인증 초기 설정 누락 | F 절; 일부 root 대화형 명령·설정 저장 이력 미확인 | OpenStack Yoga 공식 설치 가이드를 참고해 보완 |
| Provider/flat network | B048–B056 | 네트워크 실물 연결 확인 후 별도 명령으로 생성 |
| 9월 28일 gateway/NAT 및 Notification | B092–B205 | **이번 기본 Controller 설치에 미포함**; 별도 실시간 수집 장에서 다룸 |

**정확성 한계:** 실제 `~/.bash_history`의 개별 시각과 성공 여부가 남아 있지 않은 명령은 원본 실행으로 단정할 수 없다. 이 스크립트는 원본 명령을 단순 복사한 것이 아니며, 설정 파일 변경과 계정 초기화는 *재현용 보완*이다.

## 2. 사전 조건 — 먼저 사람이 확인

1. **완전히 새로 준비한 Ubuntu Server 22.04 LTS** 전용 시험 장비 또는 격리된 랩 VM. DevStack/Sunbeam/ESXi 기반으로 작성한 스크립트가 아니다.
2. 관리자 `sudo`, 인터넷 및 APT 저장소 접근, DNS, NTP 동기화. Ubuntu 기본 Yoga 패키지를 사용하며 Cloud Archive Zed 등을 섞지 않는다.
3. Controller 관리 IP는 공개용 예시 `192.0.2.81`로 변경했다. 이는 실제 네트워크에서 라우팅되지 않는 문서용 주소이므로 신규 실험 환경의 IP로 반드시 바꿔야 한다.
4. `enp1s0` 관리 NIC에는 고정 IP, 기본 경로와 DNS가 이미 구성되어 있어야 한다. `enp4s0`은 provider 네트워크 전용으로 예약하고 관리 IP를 넣지 않는다.
5. provider CIDR `192.168.100.0/24`, 게이트웨이 `192.168.100.1`, DHCP 풀 `.100–.200`은 실제 이력 값이다. **게이트웨이는 네트워크에 실제 존재해야 한다.** 원본은 9월 28일에 별도로 Linux Bridge 및 NAT를 구성했으므로, 이 작업을 하지 않으면 외부로 나가는 VM 트래픽은 동작하지 않을 수 있다.
6. Compute는 별도 서버(`com`), Cinder Volume은 별도 서버(`sto`)에서 구축한다. Controller만으로 VM 부팅·볼륨 생성 종단 검증은 불가능하다.
7. 서버·서비스 API 포트 및 관리망 방화벽 설정은 현장 정책에 따라 확인한다. MariaDB 3306, RabbitMQ 5672, Memcached 11211은 관리망에만 노출하고 인터넷에 공개하지 않는다. 과거의 암호 재사용 관행은 따르지 않는다.

## 3. 사용 방법 — 한 줄 전체 설치 (새 테스트 서버 전용)

Ubuntu 22.04가 새로 설치된 **폐기 가능한** 테스트 Controller VM에서만 사용한다. 사전 네트워크 구성이 필요하며, `CONFIRM_FRESH_HOST` 및 `CONFIRM_PROVIDER_PHYSICAL_NET`는 운영 서버를 보호하기 위한 확인 값이다.

```bash
cd ~/openstack-yoga-deployment/controller
cp controller_yoga.env.example ~/controller_yoga.env
chmod 600 ~/controller_yoga.env
nano ~/controller_yoga.env
```

`.env`의 Controller 관리 IP, `MGMT_IF`(예: `ens33`), 별도 `PROVIDER_IF`(예: `ens37`), Horizon 허용 호스트, Provider 대역/게이트웨이/풀을 새 VM 환경에 맞춰 수정한다. 모든 `<ENTER_...>` 비밀번호 자리표시자를 실제 값으로 교체한다. **비밀번호는 16자 이상일 필요가 없지만 빈 문자열은 불가하고, 허용 문자는 영문·숫자·`_`·`-`뿐이다.** 이는 SQL과 URL에 비밀번호가 직접 사용되는 현 스크립트의 안전 제한이다. 짧은 비밀번호는 실습 환경에서도 위험하므로 충분히 긴 임의의 값을 권장한다.

실제 Provider 게이트웨이·L2 연결을 검토한 신규 테스트 환경에서만:

```ini
CONFIRM_FRESH_HOST=YES_FRESH_HOST
CONFIRM_PROVIDER_PHYSICAL_NET=YES
```

실행 전 읽기 전용 점검:

```bash
bash controller_yoga.sh preflight
```

전체 자동 설치 및 설정:

```bash
bash controller_yoga.sh
```

기본 실행은 `base → keystone → glance → placement → nova → neutron → horizon → cinder → provider → verify` 순서로 자동 실행하며 실패 시 즉시 중단한다. APT 설치 단계는 `DPkg::Lock::Timeout=600`으로 다른 패키지 관리자 잠금이 풀리기를 기다린다. 패키지 관리 잠금 파일을 지우거나 `unattended-upgrades`를 강제로 종료하지 않는다.

완료된 단계에는 `~/.local/state/openstack-yoga-controller/<phase>.done` 표시가 남는다. **동일 설정에서 재실행하면 완료 표시가 있는 단계는 건너뛴다.** 단, 실패한 단계는 부분 적용됐을 수 있으므로 재시도 전에 원인을 확인해야 한다. 단계별 작업은 완전한 멱등성을 보장하지 않는다. 새 테스트 VM을 복구할 수 있도록 설치 전 스냅샷을 만들어 두는 것을 권장한다.

특정 단계만 수동으로 실행하려면 `bash controller_yoga.sh keystone` 같은 형식을 사용할 수 있다. `bash controller_yoga.sh verify`는 조회 검증이다. 상태 표시를 임의로 삭제해서 단계 재실행을 강제하면 DB·사용자·endpoint 중복이 발생할 수 있다.

**필수 구분:** 이 스크립트는 Controller만 설치한다. Compute와 Storage는 각기 다른 노드에서 별도 구축해야 한다. Provider NIC가 `DOWN`이거나 물리/가상 L2 게이트웨이가 준비되지 않았다면 실제 VM 통신은 되지 않을 수 있으므로 `CONFIRM_PROVIDER_PHYSICAL_NET=YES`로 무작정 우회하지 않는다.

## 4. 단계별 검증 기준

| 단계 | 확인 대상 | 완료 기준 |
|---|---|---|
| preflight | OS, 관리 IP, NIC, APT 후보 버전 | 22.04/Yoga 후보가 올바르고 전용 provider NIC 존재 |
| base | `systemctl is-active mariadb rabbitmq-server memcached`; `ss -lnt` | 모든 서비스 active, 관리 주소/포트 확인 |
| keystone | `openstack token issue`, `openstack project list` | admin 토큰 발급 및 service 프로젝트 표시 |
| glance | `openstack image list`; `systemctl is-active glance-api` | API 응답, 서비스 active (실제 이미지 업로드는 후속 검증) |
| placement | `sudo -u placement placement-status upgrade check` | 체크 결과에 실패가 없어야 함 |
| nova | `sudo -u nova nova-manage cell_v2 list_cells`; `openstack compute service list` | cell0·cell1과 Controller conductor/scheduler up |
| neutron | `openstack network agent list` | con의 Linux bridge, DHCP, Metadata 에이전트가 UP/Alive |
| horizon | `curl -I http://CONTROLLER_IP/horizon/auth/login/` | 로그인 페이지 정상 접근; 실제 브라우저 로그인도 확인 |
| cinder | `openstack volume service list` | Controller cinder-scheduler up; 볼륨 제공은 sto 연동 뒤 |
| provider | `openstack network show provider`, `subnet show provider-subnet` | flat/provider 네트워크·pool 존재; 별도로 물리 L2/게이트웨이 검증 |

`verify`는 서비스 검사와 CLI 상태를 출력하지만 **실제 OpenStack 기능 전체의 E2E 성공을 보증하지 않는다.** Image 업로드/다운로드, Compute VM 생성, DHCP·Metadata·VNC, Cinder 볼륨 부착/분리, 방화벽과 인증을 별도 테스트해야 한다.

## 5. 기록과 재현용 설정의 차이 및 추가 점검

- **MariaDB 최초 DB 생성 SQL**: 원본에서는 일부 로그인 이후 SQL 이력이 유실. 재현용 SQL을 새로 추가함.
- **Keystone**: 원본 history의 `db_sync`/`bootstrap`은 결과가 없어 공식 Yoga 절차를 기반으로 채움.
- **Glance 저장소**: 원본 B036의 `enabled_backends = fs:file`과 `default_backend = fs`를 유지함. APT 패키지 및 Yoga 릴리스 별 실제 사용 가능한 드라이버를 시험 환경에서 확인할 것.
- **Nova**: `nova_api`, `nova`, `nova_cell0`은 데이터베이스만 생성하고 DB 사용자는 `nova` 한 계정만 생성하도록 수정함. 세 DB 모두 `nova` 사용자에게 권한을 부여함. 원본 B020의 Cell 생성 및 B030 Placement 인증 연결을 반영함. `nova.conf`의 `use_neutron = true`는 과거 구문 오류(`use_neutron - true`)를 피하도록 수정함.
- **Neutron**: B048의 `flat,vlan`, `provider:enp4s0`, Linux Bridge 방식 반영. Gateway/NAT는 기본 설치에서 분리함.
- **Horizon**: 원본 초기 `local_settings.py` 변경 이력이 불완전하므로 핵심 설정만 재현용으로 편집함. Ubuntu 패키지에 따라 Django/Horizon 설정을 눈으로 다시 확인할 것.
- **Cinder**: Controller에는 API/Scheduler만 설치하고 Storage의 LVM/Cinder Volume 서비스는 설치하지 않음.
- **RabbitMQ Notification**: 원본 9월 28일의 `messagingv2` 설정은 **초기 인프라와 분리**. 논문의 실시간 로그 수집 구현 절에서 따로 다뤄야 함.
- **패키지 버전 및 보안**: Yoga는 역사적 재현 목적으로 선택함. 인터넷 공개 운영용 최신 지원 환경을 의미하지 않음.
- **실행 안정성**: 각 서비스 설치 단계는 clean install을 가정한다. `user create`, `endpoint create`, `create_cell` 등이 있어 단계별 작업은 완전히 멱등적이지 않다. 전체 실행은 완료 마커를 통해 동일 단계를 건너뛴다.

## 6. 근거

1. 사용자 제공 `Controller_OpenStack_Original_Commands.md`: A001–A015, B014, B020, B027–B030, B031, B035–B037, B046, B048–B056, B058–B063, F, G.
2. [Ubuntu 22.04/OpenStack Yoga](https://documentation.ubuntu.com/release-notes/22.04/)
3. [Keystone Yoga installation](https://docs.openstack.org/keystone/yoga/install/keystone-install-ubuntu.html)
4. [Glance Yoga installation](https://docs.openstack.org/glance/yoga/install/install-ubuntu.html)
5. [Placement Yoga installation](https://docs.openstack.org/placement/yoga/install/install-ubuntu.html)
6. [Nova Yoga controller installation](https://docs.openstack.org/nova/yoga/install/controller-install-ubuntu.html)
7. [Neutron Yoga provider networking](https://docs.openstack.org/neutron/yoga/install/controller-install-option1-ubuntu.html)
8. [Cinder Yoga controller installation](https://docs.openstack.org/cinder/yoga/install/cinder-controller-install-ubuntu.html)

**검증 상태:** 보고서와 공식 문서를 비교하고 Bash 구문 검사(`bash -n`)를 수행함. 깨끗한 Ubuntu 22.04 호스트에서 실제 설치·연동·VM 테스트를 수행하지 않았음.
