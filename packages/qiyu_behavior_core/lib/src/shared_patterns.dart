/// 包内共享正则：空行折叠（三连换行折叠为段落空行）。动作块剥除
/// （hidden_actions）与用户输入净化（behavior_core）共用同一形态。
/// 本文件不进入 barrel 导出，仅供包内 src 引用。
final blankLinesPattern = RegExp(r'\n{3,}');
