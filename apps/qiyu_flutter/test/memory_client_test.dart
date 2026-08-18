import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';

void main() {
  test('reads the overview and item details with GET-only requests', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/memory') {
        return _jsonResponse(_overviewJson(), 200);
      }
      if (request.url.path == '/api/memory/items/day-1') {
        return _jsonResponse(_dayDetailJson(), 200);
      }
      if (request.url.path == '/api/memory/items/gone') {
        return _jsonResponse({
          'code': 'memory_item_not_found',
          'message': '这条记忆不存在或已经变化，请返回后刷新。',
          'retryable': false,
        }, 404);
      }
      return http.Response('not found', 404);
    });
    final gateway = HttpMemoryGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final overview = await gateway.fetchOverview();
    expect(overview.recent.days.single.date, '2026-08-17');
    expect(overview.recent.days.single.finalized, isFalse);
    final entry = overview.recent.days.single.entries.single;
    expect(entry.content, '用户说这周在准备演讲');
    expect(entry.kindLabel, '记忆');
    expect(entry.hasEvidence, isTrue);
    expect(overview.longTerm.groups.single.section, '人与关系');
    expect(overview.persona.branches, hasLength(5));
    final expression = overview.persona.branches.singleWhere(
      (branch) => branch.wire == 'expression',
    );
    expect(expression.roots.single.claim, '用户尴尬时倾向自嘲');
    expect(expression.roots.single.leafCount, 2);
    expect(overview.relationship.stage, '熟悉');
    expect(overview.relationship.sharedPast.single.content, '一起聊到过深夜');

    final detail = await gateway.fetchItemDetail('day-1');
    expect(detail, isA<MemoryDayDetail>());
    expect((detail! as MemoryDayDetail).date, '2026-08-17');

    final gone = await gateway.fetchItemDetail('gone');
    expect(gone, isNull);

    // 只读红线：网关只发出 GET 请求，没有 CSRF 也没有写动作。
    expect(requests, isNotEmpty);
    for (final request in requests) {
      expect(request.method, 'GET');
      expect(request.headers.containsKey('x-qiyu-csrf'), isFalse);
    }
  });

  test('parses masked, frozen, banned and conflict markers', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/memory') {
        return _jsonResponse(_markedOverviewJson(), 200);
      }
      if (request.url.path == '/api/memory/items/middle-1') {
        return _jsonResponse(_middleDetailJson(), 200);
      }
      return http.Response('not found', 404);
    });
    final gateway = HttpMemoryGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final overview = await gateway.fetchOverview();
    final maskedEntry = overview.recent.days.single.entries.single;
    expect(maskedEntry.masked, isTrue);
    expect(maskedEntry.content, isNull);

    final frozenItem = overview.longTerm.groups.single.items.first;
    expect(frozenItem.control, MemoryControlStatus.frozen);
    expect(frozenItem.control!.label, '已冻结');
    final bannedItem = overview.longTerm.groups.single.items.last;
    expect(bannedItem.control, MemoryControlStatus.banned);

    final middle = await gateway.fetchItemDetail('middle-1');
    final middleDetail = middle! as PersonaMiddleDetail;
    expect(middleDetail.rootClaim, '用户尴尬时倾向自嘲');
    final conflictLeaf = middleDetail.leaves.singleWhere(
      (leaf) => leaf.relation == 'conflict',
    );
    expect(conflictLeaf.masked, isFalse);
    expect(conflictLeaf.dayId, isNotEmpty);
  });

  test('surfaces readable host errors', () async {
    final client = MockClient(
      (request) async => _jsonResponse({
        'code': 'internal',
        'message': '记忆中心暂时不可用，请稍后重试。',
        'retryable': true,
      }, 500),
    );
    final gateway = HttpMemoryGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );
    expect(
      () => gateway.fetchOverview(),
      throwsA(
        isA<MemoryGatewayException>().having(
          (error) => error.message,
          'message',
          '记忆中心暂时不可用，请稍后重试。',
        ),
      ),
    );
  });
}

http.Response _jsonResponse(Object body, int statusCode) => http.Response(
  jsonEncode(body),
  statusCode,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object?> _overviewJson() => {
  'generatedAt': '2026-08-17T13:00:00.000Z',
  'recent': {
    'days': [
      {
        'id': 'day-1',
        'date': '2026-08-17',
        'summary': '聊了演讲准备',
        'summaryMasked': false,
        'finalized': false,
        'entries': [
          {
            'id': 'entry-1',
            'kind': 'memory',
            'content': '用户说这周在准备演讲',
            'masked': false,
            'at': '2026-08-17T12:00:00.000Z',
            'hasEvidence': true,
          },
        ],
      },
    ],
  },
  'longTerm': {
    'present': true,
    'readable': true,
    'organizedAt': '2026-08-16T14:00:00.000Z',
    'groups': [
      {
        'section': '人与关系',
        'items': [
          {'content': '用户和家人关系亲近', 'masked': false},
        ],
      },
    ],
  },
  'persona': {
    'branches': [
      for (final branch in [
        ('identity', '身份事实'),
        ('expression', '性格表达'),
        ('values', '价值原则'),
        ('preferences', '偏好习惯'),
        ('boundaries', '边界禁区'),
      ])
        {
          'wire': branch.$1,
          'title': branch.$2,
          'readable': true,
          'roots': branch.$1 == 'expression'
              ? [
                  {
                    'id': 'root-1',
                    'claim': '用户尴尬时倾向自嘲',
                    'masked': false,
                    'middleCount': 1,
                    'leafCount': 2,
                    'earliestEvidence': '2026-07-10',
                    'latestEvidence': '2026-07-16',
                  },
                ]
              : <Object?>[],
          'unrooted': <Object?>[],
        },
    ],
  },
  'relationship': {
    'present': true,
    'stage': '熟悉',
    'since': '2026-08-01',
    'confirmed': [
      {'content': '可以自然提起说过的事', 'masked': false},
    ],
    'probes': <Object?>[],
    'recentChanges': [
      {'content': '聊得比平时深一些', 'masked': false},
    ],
    'sharedPast': [
      {'content': '一起聊到过深夜', 'masked': false},
    ],
  },
};

Map<String, Object?> _markedOverviewJson() => {
  'generatedAt': '2026-08-17T13:00:00.000Z',
  'recent': {
    'days': [
      {
        'id': 'day-1',
        'date': '2026-08-17',
        'summaryMasked': false,
        'finalized': true,
        'entries': [
          {
            'id': 'entry-1',
            'kind': 'memory',
            'masked': true,
            'at': '2026-08-17T12:00:00.000Z',
            'hasEvidence': false,
          },
        ],
      },
    ],
  },
  'longTerm': {
    'present': true,
    'readable': true,
    'groups': [
      {
        'section': '人与关系',
        'items': [
          {'content': '冻结的印象', 'masked': false, 'control': 'frozen'},
          {'content': '禁提的印象', 'masked': false, 'control': 'banned'},
        ],
      },
    ],
  },
  'persona': {'branches': <Object?>[]},
  'relationship': {
    'present': false,
    'confirmed': <Object?>[],
    'probes': <Object?>[],
    'recentChanges': <Object?>[],
    'sharedPast': <Object?>[],
  },
};

Map<String, Object?> _dayDetailJson() => {
  'kind': 'day',
  'date': '2026-08-17',
  'summary': '聊了演讲准备',
  'summaryMasked': false,
  'finalized': false,
  'entries': <Object?>[],
};

Map<String, Object?> _middleDetailJson() => {
  'kind': 'persona-middle',
  'branch': 'expression',
  'branchTitle': '性格表达',
  'type': '重复模式',
  'claim': '被关注时常用玩笑降低郑重感',
  'masked': false,
  'formedOn': '2026-07-16',
  'reviewedOn': '2026-07-16',
  'rootClaim': '用户尴尬时倾向自嘲',
  'leaves': [
    {
      'dayId': 'day-leaf-1',
      'date': '2026-07-10',
      'nature': '行为观察',
      'relation': 'support',
      'summary': '被认真夸奖后马上自嘲',
      'masked': false,
    },
    {
      'dayId': 'day-leaf-2',
      'date': '2026-07-16',
      'nature': '行为观察',
      'relation': 'conflict',
      'summary': '这次认真道谢了',
      'masked': false,
    },
  ],
};
