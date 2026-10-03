// 通话播放平台的缺省实现（web 与测试宿主）：没有通话专用播放器。
//
// web 构建的通话播放沿用 T04 缺省装配（浏览器流式播放器，控制器回退
// 创建）；本文件就是「不注入」的显式形状——工厂返回 null，OmniCall
// Controller 收到后走自己的 `_resolveStreamingPlayer` 缺省。
import 'voice_player_platform.dart';

StreamingVoicePlayerPlatform? createOmniCallPlayerPlatform() => null;
