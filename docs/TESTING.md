# 测试策略与实盘检测清单

## 分层

| 层 | 命令 | 说明 |
|---|---|---|
| 单元测试 | `make test` | 纯算法层；真实盘 fixture 黄金对照；无需 root |
| 集成测试 | `make test-integration` | sudo + macFUSE；合成盘全链路（probe/mount/写/unmount/重挂/readonly/错误密码） |
| 协议测试 | `make test`（daemon 测试模块） | 非 root 跑 daemon，socket 序列断言 |
| CLI 在线模式 | `cargo test -p usbcore --test online_mode` | 非 root / 无 macFUSE：临时 daemon + CLI 走 RPC |
| GUI | `cargo build --manifest-path gui/src-tauri/Cargo.toml` + `npm run build` | 前端 vue-tsc + 后端编译；CI 门禁 |
| 实盘检测 | 手动（下表） | 每里程碑必做，交付前完整执行 |

## GUI 手工验收（M3 起）

- [ ] `npx tauri dev` 启动：状态栏出现图标，无 Dock 图标；窗口默认隐藏，点托盘/左键打开
- [ ] 密码库页：添加密码（选插入的盘→输密码→保存）→ 密码库列出（脱敏）
- [ ] 设置页：daemon 未运行提示 + 「安装 daemon」提权成功；macFUSE 状态正确显示
- [ ] 插入已登记密码盘 ≤5s 自动挂载，系统通知弹出，托盘菜单出现挂载项
- [ ] 托盘点击挂载项 → Finder 打开；卸载后托盘菜单更新；GUI 退出后 daemon 仍自动挂载

## 黄金对照

`fixtures/golden/` 由 Python 参考实现在开发期一次性离线生成（**只入库数据文件**），
Rust 单测用 serde 读取，保证移植逐字节等价。

## 实盘检测清单（disk4 Lexar + disk5 SanDisk，逐盘执行）

- [ ] M1 手动挂载：`sudo usbcore mount /dev/rdiskN` 成功，Finder 可读写 exFAT，写入文件卸载重挂后仍在
- [ ] M1 identify 兜底：disk5 免 `--device-id` 挂载
- [ ] M2 自动挂载：密码入库后插入 ≤5s 自动挂载（GUI 不在线），拔盘自动清理
- [ ] M2 双盘并发：两盘同插各自挂载、互不干扰、分别卸载
- [ ] M2 密码错误路径：错误密码入库 → `password_needed` 事件、不挂载、daemon 不崩
- [ ] M4 交付全流程：拷 .app → 装 macFUSE → 装 daemon → 冷启动插盘即挂载 → 读写 → 卸载 → 拔盘
- [ ] M4 回归：`sudo cargo test -- --ignored` 全绿

## 密码双路径覆盖

- 路径A（默认密码 0000aaaa）：两块真实盘实测覆盖
- 路径B（修改后密码）：合成向量自洽测试；`TODO(real-disk)` 待改密盘实测校准
