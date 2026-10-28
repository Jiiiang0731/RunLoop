import 'package:flutter/material.dart';

/// 首次启动的隐私政策同意页。
///
/// 用户点击「同意并继续」后才会初始化高德 SDK（见 main.dart）。
/// 这是高德 SDK 合规要求的前置条件，不能绕过。
class ConsentScreen extends StatelessWidget {
  const ConsentScreen({super.key, required this.onAgree});

  final VoidCallback onAgree;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '欢迎使用环跑',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    '使用本应用前，请阅读并同意以下说明：\n\n'
                    '1. 本应用使用高德地图与定位 SDK，用于展示地图、获取您的实时位置。\n'
                    '2. 您的定位与跑步数据仅保存在本机（本地数据库），不会上传到服务器。\n'
                    '3. 定位信息用于在地图上显示当前位置、记录跑步轨迹与计算距离。\n'
                    '4. 您可随时在系统设置中关闭定位权限。\n\n'
                    '点击「同意并继续」表示您已阅读并同意上述说明；若不同意，将无法使用地图与定位功能。',
                    style: TextStyle(fontSize: 15, height: 1.6),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onAgree,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('同意并继续'),
                  ),
                ),
              ),
              Center(
                child: TextButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('需同意隐私说明后才能使用地图与定位')),
                    );
                  },
                  child: const Text('不同意'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
