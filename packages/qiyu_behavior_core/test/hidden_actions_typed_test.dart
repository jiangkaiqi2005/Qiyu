import 'dart:convert';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

void main() {
  group('typed hidden action models', () {
    test('each kind carries only its own validated shape', () {
      const signal = MemorySignalAction(summary: '用户明天有面试');
      expect(signal.kind, HiddenActionKind.memorySignal);
      expect(signal.evidence, isNull);
      expect(signal.hint, isNull);

      final recall = MemoryRecallAction(query: '上次说的那本书');
      expect(recall.kind, HiddenActionKind.memoryRecall);
      expect(recall.months, isNull);
      expect(recall.dates, isNull);

      const noAction = NoAction();
      expect(noAction.kind, HiddenActionKind.noAction);

      const candidate = OpenLoopCandidateAction(title: '人生第一次演讲');
      expect(candidate.kind, HiddenActionKind.openLoopCandidate);

      const status = OpenLoopStatusAction(
        title: '人生第一次演讲',
        status: LoopStatus.closed,
      );
      expect(status.kind, HiddenActionKind.openLoopStatus);

      const ban = MemoryBanAction(title: '医院检查');
      expect(ban.kind, HiddenActionKind.memoryBan);
      const forget = MemoryForgetAction(title: '今晚的争吵');
      expect(forget.kind, HiddenActionKind.memoryForget);
      const freeze = MemoryFreezeAction(title: '换工作话题');
      expect(freeze.kind, HiddenActionKind.memoryFreeze);
      const unfreeze = MemoryUnfreezeAction(title: '换工作话题');
      expect(unfreeze.kind, HiddenActionKind.memoryUnfreeze);
      const delete = MemoryDeleteAction(title: '医院检查');
      expect(delete.kind, HiddenActionKind.memoryDelete);

      const relationship = RelationshipSignalAction(
        summary: '用户近期愿意聊到更深的家庭关系',
        signal: RelationshipSignal.deepTalk,
      );
      expect(relationship.kind, HiddenActionKind.relationshipSignal);
    });

    test('persona hints are always a branch and nature pair', () {
      const hint = PersonaHint(
        branch: PersonaTreeBranch.identity,
        nature: PersonaNature.selfReport,
      );
      const signal = MemorySignalAction(summary: '用户养了一只叫米子的猫', hint: hint);
      expect(signal.hint?.branch, PersonaTreeBranch.identity);
      expect(signal.hint?.nature, PersonaNature.selfReport);
    });

    test('whitelist enums keep their wire names', () {
      expect(LoopStatus.tryParseWireName('closed'), LoopStatus.closed);
      expect(LoopStatus.tryParseWireName('done'), isNull);
      expect(
        LoopProactive.tryParseWireName('once'),
        LoopProactive.once,
      );
      expect(
        PersonaTreeBranch.tryParseWireName('boundaries'),
        PersonaTreeBranch.boundaries,
      );
      expect(
        PersonaNature.tryParseWireName('self_report'),
        PersonaNature.selfReport,
      );
      expect(
        RelationshipSignal.tryParseWireName('boundary_close'),
        RelationshipSignal.boundaryClose,
      );
      expect(RelationshipSignal.tryParseWireName('mood'), isNull);
    });

    test('recall selections stay immutable on the typed model', () {
      final recall = MemoryRecallAction(
        query: '火锅店',
        months: ['2026-07'],
        dates: ['2026-07-14'],
      );
      expect(() => recall.months!.add('2026-08'), throwsUnsupportedError);
      expect(() => recall.dates!.add('2026-07-15'), throwsUnsupportedError);
    });

    test('serialization keeps the wire keys of the flat protocol', () {
      expect(
        jsonEncode(const MemorySignalAction(summary: '早睡').toJson()),
        '{"action":"memory_signal","summary":"早睡"}',
      );
      expect(
        jsonEncode(
          const MemorySignalAction(
            summary: '用户养了一只叫米子的猫',
            evidence: '我家米子',
            hint: PersonaHint(
              branch: PersonaTreeBranch.identity,
              nature: PersonaNature.selfReport,
            ),
          ).toJson(),
        ),
        '{"action":"memory_signal","summary":"用户养了一只叫米子的猫",'
        '"evidence":"我家米子","branch":"identity","nature":"self_report"}',
      );
      expect(
        jsonEncode(
          MemoryRecallAction(
            query: '火锅店',
            months: ['2026-07'],
            dates: ['2026-07-14'],
          ).toJson(),
        ),
        '{"action":"memory_recall","query":"火锅店",'
        '"months":["2026-07"],"dates":["2026-07-14"]}',
      );
      expect(
        jsonEncode(const NoAction().toJson()),
        '{"action":"no_action"}',
      );
      expect(
        jsonEncode(
          const OpenLoopCandidateAction(
            title: '人生第一次演讲',
            evidence: '下周三是人生第一次演讲',
            due: '2026-07-05 晚上',
            proactive: LoopProactive.once,
            note: '用户说这是人生第一次演讲',
          ).toJson(),
        ),
        '{"action":"open_loop_candidate","summary":"人生第一次演讲",'
        '"evidence":"下周三是人生第一次演讲","due":"2026-07-05 晚上",'
        '"proactive":"once","note":"用户说这是人生第一次演讲"}',
      );
      expect(
        jsonEncode(
          const OpenLoopStatusAction(
            title: '人生第一次演讲',
            status: LoopStatus.closed,
            result: '用户说演讲很顺利',
          ).toJson(),
        ),
        '{"action":"open_loop_status","summary":"人生第一次演讲",'
        '"status":"closed","result":"用户说演讲很顺利"}',
      );
      expect(
        jsonEncode(
          const OpenLoopCandidateAction(
            title: '租房事宜',
            keep: memorySignalKeepMonth,
          ).toJson(),
        ),
        '{"action":"open_loop_candidate","summary":"租房事宜","keep":"month"}',
      );
      expect(
        jsonEncode(
          const RelationshipSignalAction(
            summary: '用户近期愿意聊到更深的家庭关系',
            signal: RelationshipSignal.deepTalk,
            keep: memorySignalKeepMonth,
          ).toJson(),
        ),
        '{"action":"relationship_signal",'
        '"summary":"用户近期愿意聊到更深的家庭关系",'
        '"signal":"deep_talk","keep":"month"}',
      );
      expect(
        jsonEncode(const MemoryBanAction(title: '医院检查').toJson()),
        '{"action":"memory_ban","summary":"医院检查"}',
      );
      expect(
        jsonEncode(
          const MemorySignalAction(
            summary: '用户认定长期记忆只放极度压缩的人生记忆',
            keep: memorySignalKeepMonth,
          ).toJson(),
        ),
        '{"action":"memory_signal",'
        '"summary":"用户认定长期记忆只放极度压缩的人生记忆",'
        '"keep":"month"}',
      );
      expect(
        jsonEncode(
          const RelationshipSignalAction(
            summary: '用户接受了轻调侃',
            signal: RelationshipSignal.boundaryOpen,
            evidence: '被调侃后反逗了一句',
          ).toJson(),
        ),
        '{"action":"relationship_signal","summary":"用户接受了轻调侃",'
        '"evidence":"被调侃后反逗了一句","signal":"boundary_open"}',
      );
    });

    test('the sealed family stays exhaustive over all eleven kinds', () {
      String wire(HiddenAction action) => switch (action) {
        MemorySignalAction() => 'memory_signal',
        MemoryRecallAction() => 'memory_recall',
        NoAction() => 'no_action',
        OpenLoopCandidateAction() => 'open_loop_candidate',
        OpenLoopStatusAction() => 'open_loop_status',
        MemoryBanAction() => 'memory_ban',
        MemoryForgetAction() => 'memory_forget',
        MemoryFreezeAction() => 'memory_freeze',
        MemoryUnfreezeAction() => 'memory_unfreeze',
        MemoryDeleteAction() => 'memory_delete',
        RelationshipSignalAction() => 'relationship_signal',
      };

      final actions = <HiddenAction>[
        const MemorySignalAction(summary: '甲'),
        MemoryRecallAction(query: '乙'),
        const NoAction(),
        const OpenLoopCandidateAction(title: '丙'),
        const OpenLoopStatusAction(title: '丁', status: LoopStatus.active),
        const MemoryBanAction(title: '戊'),
        const MemoryForgetAction(title: '己'),
        const MemoryFreezeAction(title: '庚'),
        const MemoryUnfreezeAction(title: '辛'),
        const MemoryDeleteAction(title: '壬'),
        const RelationshipSignalAction(
          summary: '癸',
          signal: RelationshipSignal.temperature,
        ),
      ];
      expect(
        actions.map(wire),
        HiddenActionKind.values.map((kind) => kind.wireName),
      );
    });

    test('typed equality compares shape field by field', () {
      expect(
        MemoryRecallAction(query: '火锅店', months: ['2026-07']),
        MemoryRecallAction(query: '火锅店', months: ['2026-07']),
      );
      expect(
        MemoryRecallAction(query: '火锅店', months: ['2026-07']),
        isNot(MemoryRecallAction(query: '火锅店')),
      );
      expect(
        const MemoryBanAction(title: '医院检查'),
        isNot(const MemoryDeleteAction(title: '医院检查')),
      );
      expect(
        const MemorySignalAction(
          summary: '猫',
          hint: PersonaHint(
            branch: PersonaTreeBranch.preferences,
            nature: PersonaNature.behavior,
          ),
        ),
        const MemorySignalAction(
          summary: '猫',
          hint: PersonaHint(
            branch: PersonaTreeBranch.preferences,
            nature: PersonaNature.behavior,
          ),
        ),
      );
      // keep 参与相等性：标没标月压缩候选是两条不同的记忆。
      expect(
        const MemorySignalAction(summary: '猫', keep: memorySignalKeepMonth),
        isNot(const MemorySignalAction(summary: '猫')),
      );
      expect(
        const MemorySignalAction(summary: '猫', keep: memorySignalKeepMonth),
        const MemorySignalAction(summary: '猫', keep: memorySignalKeepMonth),
      );
      expect(
        const MemorySignalAction(
          summary: '猫',
          keep: memorySignalKeepMonth,
        ).hashCode,
        const MemorySignalAction(
          summary: '猫',
          keep: memorySignalKeepMonth,
        ).hashCode,
      );
      // 两类生命周期动作的 keep 同样参与相等性。
      expect(
        const OpenLoopCandidateAction(title: '租房事宜', keep: memorySignalKeepMonth),
        isNot(const OpenLoopCandidateAction(title: '租房事宜')),
      );
      expect(
        const OpenLoopCandidateAction(
          title: '租房事宜',
          keep: memorySignalKeepMonth,
        ).hashCode,
        const OpenLoopCandidateAction(
          title: '租房事宜',
          keep: memorySignalKeepMonth,
        ).hashCode,
      );
      expect(
        const RelationshipSignalAction(
          summary: '用户近期愿意聊家庭',
          signal: RelationshipSignal.deepTalk,
          keep: memorySignalKeepMonth,
        ),
        isNot(
          const RelationshipSignalAction(
            summary: '用户近期愿意聊家庭',
            signal: RelationshipSignal.deepTalk,
          ),
        ),
      );
      expect(
        const RelationshipSignalAction(
          summary: '用户近期愿意聊家庭',
          signal: RelationshipSignal.deepTalk,
          keep: memorySignalKeepMonth,
        ).hashCode,
        const RelationshipSignalAction(
          summary: '用户近期愿意聊家庭',
          signal: RelationshipSignal.deepTalk,
          keep: memorySignalKeepMonth,
        ).hashCode,
      );
    });
  });
}
