// The faces' eyes on the voice stage look toward whoever speaks, in the grid and while a tile is shown large (#296).
import 'package:duvet/widgets/voice_video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  VoicePerson person(String id) => VoicePerson(id: id, name: id);
  final ana = person('ana'), leo = person('leo'), mia = person('mia'), kai = person('kai');
  VoiceTile tile(VoicePerson p, {bool screen = false}) =>
      (key: '${screen ? 'screen' : 'person'}:${p.id}', person: p, screen: screen);

  test('in a grid, each face looks toward the speaker\'s tile, and the speaker straight ahead', () {
    final people = [ana, leo, mia, kai];
    final eyes = eyesToward(people, {'mia': 0.5}, gridPlaces(people, 2));
    expect(eyes['ana'], const Offset(0, 0.8));
    expect(eyes['leo'], offsetMoreOrLessEquals(const Offset(-0.566, 0.566), epsilon: 0.001));
    expect(eyes['kai'], const Offset(-0.8, 0));
    expect(eyes.containsKey('mia'), isFalse);
    expect(eyesToward(people, const {}, gridPlaces(people, 2)), isEmpty);
  });

  test('with a screen shown large, the faces in the strip look along it at the speaker', () {
    final stage = stagePlaces(tile(leo, screen: true), [tile(ana), tile(leo), tile(mia)]);
    expect(eyesToward([ana, leo, mia], {'mia': 0.5}, stage), {
      'ana': const Offset(0.8, 0),
      'leo': const Offset(0.8, 0),
    });
  });

  test('with a person shown large, the strip looks up at them, and they down at a speaker in it', () {
    final stage = stagePlaces(tile(mia), [tile(ana), tile(leo)]);
    expect(stage, {'mia': const Offset(0.5, -1), 'ana': Offset.zero, 'leo': const Offset(1, 0)});
    final up = eyesToward([ana, leo, mia], {'mia': 0.5}, stage);
    expect(up['ana'], offsetMoreOrLessEquals(const Offset(0.358, -0.716), epsilon: 0.001));
    expect(up['leo'], offsetMoreOrLessEquals(const Offset(-0.358, -0.716), epsilon: 0.001));
    final down = eyesToward([ana, leo, mia], {'leo': 0.5}, stage);
    expect(down['mia'], offsetMoreOrLessEquals(const Offset(0.358, 0.716), epsilon: 0.001));
    expect(down['ana'], const Offset(0.8, 0));
  });
}
