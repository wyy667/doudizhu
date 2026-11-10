import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/home/home_screen.dart';

/// 应用入口。
///
/// 强制横屏（参见 docs/09-design-mvp.md §2）。运行后进入主菜单。
/// Supabase 采用懒加载：仅当用户进入联机模式时才初始化。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 锁定横屏
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  // 沉浸式全屏（隐藏状态栏和导航栏）
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(const ProviderScope(child: LandlordApp()));
}

class LandlordApp extends StatelessWidget {
  const LandlordApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '斗地主',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1B5E20),
        useMaterial3: true,
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF2E7D32),
          titleTextStyle: TextStyle(
            color: Colors.amber,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          contentTextStyle: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
