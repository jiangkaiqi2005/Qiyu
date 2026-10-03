// Omni 通话播放平台的条件出口（T05）：通话的下行播放不走通用朗读平台
// （IoVoicePlayerPlatform 绑定 Activity 前台，后台通话会被前台闸挡死），
// 而是走原生通话桥的专用流——生命周期归通话（前台服务锚定），与采集
// 共用通话级焦点，同时录放。
//
// - io（安卓壳生产宿主）：[AndroidOmniCallPlayerPlatform]，原生桥承载。
// - web 与缺省（测试宿主）：返回 null——控制器回退既有缺省装配（web
//   的浏览器播放器），行为与 T04 零变化。
export 'omni_call_player_platform_stub.dart'
    if (dart.library.js_interop) 'omni_call_player_platform_stub.dart'
    if (dart.library.io) 'omni_call_player_platform_io.dart';
