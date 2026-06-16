# convoypanel-scripts

[![hits](https://hits.spiritlhl.net/convoy.svg?action=hit&title=hits&title_bg=%23555555&count_bg=%233aebee&edge_flat=false)](https://hits.spiritlhl.net)

## 说明

中文：

https://www.spiritlhl.net/incomplete/convoy.html

English:

https://www.spiritlhl.net/en/incomplete/convoy.html

## Install / 安装

```bash
bash installconvoy.sh
```

Pin a release / 固定版本：

```bash
bash installconvoy.sh --convoy-version v2.0.3-beta --broker-version latest
```

Useful options / 常用选项：

- `--force`: continue if `/var/www/convoy` already has files / 目录已有文件时继续。
- `--no-rollback`: keep created resources after failure / 失败后保留已创建资源。
- `--skip-network-check`: skip GitHub, Docker Hub, and local PVE API checks / 跳过网络预检。
- `--skip-swap`: fail instead of creating swap automatically / 内存不足时不自动创建 swap，而是直接失败。
- `--skip-admin`: skip the interactive admin creation command / 跳过交互式管理员创建。

The installer writes a persistent log to `/var/log/convoypanel-scripts/`.
安装日志会持久化到 `/var/log/convoypanel-scripts/`。

## Uninstall / 卸载

```bash
bash uninstallconvoy.sh --yes
```

Remove local project images and logs as well / 同时删除本项目本地镜像和日志：

```bash
bash uninstallconvoy.sh --yes --remove-images --remove-logs
```
