#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RunLoop 生产入口（waitress WSGI，Windows 原生）。

部署形态（用户阶段 K 决策：Tailscale 个人私有网络，零月租）：
    waitress (127.0.0.1:8000)  ←— Tailscale Serve —←  手机 (Tailnet HTTPS)

- 仅监听本机回环：校园局域网/公网都碰不到这个端口；
- Tailscale Serve 负责 Tailnet 内的 HTTPS(443) 证书与反代；
- 不使用 Flask 开发服务器（用户规范 6.3），不用 Gunicorn（不支持 Windows）。

启动：python backend/serve.py
环境变量：
    RUNLOOP_HOST        默认 127.0.0.1（生产勿改；改动即失去回环保护）
    RUNLOOP_PORT        默认 8000
    RUNLOOP_AMAP_KEY    高德 Web Key（不设则读 config/amap_key.local）
    RUNLOOP_ENV         production(默认) / development
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)


def main():
    from waitress import serve
    from backend.server import SERVICE_VERSION, app

    host = os.environ.get("RUNLOOP_HOST", "127.0.0.1")
    port = int(os.environ.get("RUNLOOP_PORT", "8000"))
    threads = int(os.environ.get("RUNLOOP_THREADS", "6"))

    print(f"RunLoop 路线 API v{SERVICE_VERSION}（waitress 生产模式）")
    print(f"监听 http://{host}:{port}  threads={threads}")
    if host == "127.0.0.1":
        print("回环监听：请通过 Tailscale Serve 暴露为 Tailnet HTTPS（tailscale serve --bg 8000）")
    else:
        print("警告：非回环监听，端口对本局域网可见！仅调试时使用。")

    serve(
        app,
        host=host,
        port=port,
        threads=threads,
        # 生成一次路线可能耗时 30~120s：加大通道超时，避免慢响应被掐断
        channel_timeout=900,
        connection_limit=32,
        max_request_body_size=256 * 1024,
        ident="RunLoopAPI/" + SERVICE_VERSION,
    )


if __name__ == "__main__":
    main()
