import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/audio/card_announcer.dart';
import 'package:landlord/core/card.dart';

void main() {
  Card c(int i) => Card.fromIndex(i);

  test('单 / 对 / 三张读点数', () {
    expect(CardAnnouncer.playText([c(0)]), '三');
    expect(CardAnnouncer.playText([c(48), c(49)]), '对二');
    expect(CardAnnouncer.playText([c(32), c(33), c(34)]), '三个J');
    expect(CardAnnouncer.playText([c(53)]), '大王');
  });

  test('组合牌型读牌型名', () {
    expect(CardAnnouncer.playText([c(0), c(1), c(2), c(4)]), '三带一');
    expect(CardAnnouncer.playText([c(0), c(4), c(8), c(12), c(16)]), '顺子');
    expect(CardAnnouncer.playText([c(0), c(1), c(2), c(3)]), '炸弹');
    expect(CardAnnouncer.playText([c(52), c(53)]), '王炸');
  });
}
