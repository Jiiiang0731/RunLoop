# 高德地图 Web 服务 API 调研与实测记录

> 原则：不编造接口/参数/返回字段，一切以官方文档 + 真实调用为准。
> 密钥：`config/amap_key.local`（已 gitignore，不入库）。

## 1. 官方文档依据

- 路径规划（direction v3）：https://lbs.amap.com/api/webservice/guide/api/direction
- 路径规划 2.0（newroute）：https://lbs.amap.com/api/webservice/guide/api/newroute
- Web Service 总览：https://developer.amap.com/api/web-service/guide/routes
- 坐标转换：https://lbs.amap.com/api/webservice/guide/api/convert
- 配额/封禁 FAQ：https://developer.amap.com/faq/quota-key/key/41207
- 流量限制说明：https://amap.apifox.cn/doc-541078

## 2. 实测记录（Python 脚本 `backend/verify_amap.py`、`verify_amap_extra.py`）

### 2.1 地理编码 `/v3/geocode/geo`
- 请求：`address=上海世纪公园&city=上海`
- 返回：`status=1, infocode=10000, info=OK`，`location=121.552563,31.215725`，`level=兴趣点`，耗时 0.21s。
- 结论：地址→GCJ-02 坐标可用。

### 2.2 步行路径规划 `/v3/direction/walking`（核心）
- 请求：`origin=116.397428,39.909230&destination=116.417428,39.909230`（天安门东 1.7km）
- 返回：`status=1, infocode=10000`；`route.paths[0]` 仅有三个顶层字段 **`distance` / `duration` / `steps`**。
  - `distance=3020`（**字符串类型**）、`duration=2416`（字符串）、`steps=9`。
- `step` 字段：`action, assistant_action, distance, duration, instruction, orientation, polyline, road, walk_type`。
- `polyline` 格式：`"116.397435,39.909227;116.397387,39.910373;..."`（**分号分隔点，点内逗号分隔 lng,lat，6 位小数**）。
- `instruction` 示例：「向北步行391米后左转」（中文导航指令）。
- **关键坑**：`distance`/`duration` 是字符串，代码必须 `int(float(...))` 转换，否则算术报错（已在 `loop_gen.py` 修复）。

### 2.3 骑行路径规划 `/v3/direction/bicycle`
- 返回：`status=0, infocode=10002, info=SERVICE_NOT_AVAILABLE`。
- 结论：**当前 Key 未开通骑行服务**。属 Key 权限问题，非接口不存在。首版以步行规划为主，不影响核心闭环功能。

### 2.4 驾车路径规划 `/v3/direction/driving`
- 返回：`status=1`，约 4.8km 直线对点实际道路 `distance=6413`（字符串）。
- 结论：可用，作为备选/参考（跑步不用驾车，但可对比道路）。

### 2.5 坐标转换 `/v3/assistant/coordinate/convert`
- 请求：`locations=116.391275,39.907500&coordsys=gps`
- 返回：`status=1`，输出 `116.397515190973,39.908900553386`，耗时 0.13s。
- 结论：WGS-84(GPS) → GCJ-02 可用，偏移量符合预期（北京约 +0.006 经度）。

### 2.6 「无路」边界
- 海面点步行规划仍返回 `status=1`，但可能 `paths` 为空；代码需同时判断 `paths` 非空（`loop_gen.py` 已处理）。

## 3. 坐标系结论

- 高德全链路用 **GCJ-02**；手机 GPS 是 **WGS-84**。
- 内部规范：定位原始值保留 WGS-84；进地图/规划前转 GCJ-02；展示与规划统一 GCJ-02。
- 高频 GPS 点建议用开源离线转换（eviltransform/coordtransform），批量场景用官方在线接口。

## 4. 配额与限制

- 免费个人开发者有**每日配额与 QPS** 限制（具体数值以控制台「配额中心」为准，本报告不杜撰数字）。
- 超限错误码：`10003`（DAILY_QUERY_OVER_LIMIT，日配额超限）、`10004`（QPS 超限）等；需在客户端明确提示。
- 本次验证累计约 183 次调用，未触发任何限流。
- 环线生成单候选约 11–33 次调用；3 候选约 23s。为控制配额，限制候选数与迭代数。

## 5. 对环线生成的启示

1. 步行 API 返回真实道路距离 + 中文导航指令 + 折线，满足「真实距离 + 导航步骤」需求。
2. `distance` 是字符串，需转换。
3. 折线需自行拼接各 step 的 polyline。
4. 骑行/绿道属性不能直接获得；公园/绿道优先需借助 POI 搜索（阶段 2 评估）。
5. 外部导航跳转（高德 URI Scheme）需在阶段 5 查证当前有效规范。
