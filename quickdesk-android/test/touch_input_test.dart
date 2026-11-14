import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickdesk_android/controller/touch_input.dart';
import 'package:quickdesk_android/controller/touch_pointer_router.dart';
import 'package:quickdesk_android/protocol/datachannel_handler.dart';
import 'package:quickdesk_android/protocol/proto/protobuf_messages.dart';

class _RecordingDataChannelHandler extends DataChannelHandler {
  final List<MouseEventMsg> mouseEvents = [];

  @override
  void sendMouseEvent(MouseEventMsg mouseEvent) {
    mouseEvents.add(mouseEvent);
  }
}

PointerDownEvent _down(Offset position, {int pointer = 1}) =>
    PointerDownEvent(pointer: pointer, position: position);

PointerMoveEvent _move(Offset position, {int pointer = 1}) =>
    PointerMoveEvent(pointer: pointer, position: position);

PointerUpEvent _up(Offset position, {int pointer = 1}) =>
    PointerUpEvent(pointer: pointer, position: position);

void _tap(TouchInputController controller, Offset position) {
  controller.onPointerDown(_down(position), 1);
  controller.onPointerUp(_up(position), 0);
}

void main() {
  late _RecordingDataChannelHandler channel;
  late TouchInputController controller;

  setUp(() {
    channel = _RecordingDataChannelHandler();
    controller = TouchInputController(channel)
      ..setRemoteResolution(1000, 800)
      ..setViewportSize(400, 800);
  });

  tearDown(() async {
    controller.dispose();
    await channel.dispose();
  });

  for (final origin in [
    Offset.zero,
    const Offset(1920, 100),
    const Offset(-1000, -800),
  ]) {
    test('display origin $origin maps clicks, drag and scroll, not local cursor', () {
      controller.setRemoteDisplay(
        1000,
        800,
        originX: origin.dx.toInt(),
        originY: origin.dy.toInt(),
      );
      _tap(controller, const Offset(100, 100));
      controller.click(right: true);
      controller.onPointerDown(_down(const Offset(100, 200)), 1);
      controller.onPointerDown(_down(const Offset(200, 200), pointer: 2), 2);
      controller.onTwoFingerStart(const Offset(150, 200), 100);
      controller.onPointerMove(_move(const Offset(110, 215)), 2,
          twoFingerCenter: const Offset(160, 215), twoFingerDistance: 100);
      controller.onPointerUp(_up(const Offset(110, 215)), 0);
      for (final event in channel.mouseEvents) {
        expect(event.x, origin.dx.toInt() + 500);
        expect(event.y, origin.dy.toInt() + 400);
      }
      expect(channel.mouseEvents.last.wheelDeltaY, 45);
      final wireEvent = decodeEventMessage(encodeEventMessage(
        mouseEvent: channel.mouseEvents.last,
      )).mouseEvent!;
      expect(wireEvent.x, origin.dx.toInt() + 500);
      expect(wireEvent.y, origin.dy.toInt() + 400);
      channel.mouseEvents.clear();
      controller.toggleDrag();
      controller.onPointerDown(_down(const Offset(100, 100)), 1);
      controller.onPointerMove(_move(const Offset(10000, -10000)), 1);
      controller.onPointerUp(_up(const Offset(10000, -10000)), 0);
      expect(channel.mouseEvents.map((e) => [e.x, e.y]).toList(), [
        [origin.dx.toInt() + 500, origin.dy.toInt() + 400],
        [origin.dx.toInt() + 999, origin.dy.toInt()],
        [origin.dx.toInt() + 999, origin.dy.toInt()],
      ]);
      expect(controller.cursorX, 999);
      expect(controller.cursorY, 0);
    });
  }

  test('switch releases drag at old origin and frame resize preserves mapping', () {
    controller.setRemoteDisplay(1000, 800, originX: -1000, originY: 100);
    controller.toggleDrag();
    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    controller.onPointerMove(_move(const Offset(120, 100)), 1);
    controller.setRemoteDisplay(400, 600, originX: 1920, originY: -600);
    expect(channel.mouseEvents.last.buttonDown, isFalse);
    expect(channel.mouseEvents.last.x, -450);
    expect(channel.mouseEvents.last.y, 500);
    controller.onPointerUp(_up(const Offset(120, 100)), 0);
    controller.setRemoteResolution(400, 600);
    controller.click();
    expect(channel.mouseEvents.last.x, 2319);
    expect(channel.mouseEvents.last.y, -200);
    controller.setRemoteDisplay(400, 600);
    controller.click();
    expect(channel.mouseEvents.last.x, 399);
    expect(channel.mouseEvents.last.y, 400);
  });

  test('single tap emits an immediate left click', () {
    _tap(controller, const Offset(100, 100));

    expect(channel.mouseEvents, hasLength(2));
    expect(channel.mouseEvents[0].button, MouseButton.left.value);
    expect(channel.mouseEvents[0].buttonDown, isTrue);
    expect(channel.mouseEvents[1].button, MouseButton.left.value);
    expect(channel.mouseEvents[1].buttonDown, isFalse);
  });

  test('tap released before long-press threshold is not dropped', () async {
    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.onPointerUp(_up(const Offset(100, 100)), 0);

    expect(channel.mouseEvents, hasLength(2));
    expect(channel.mouseEvents[0].buttonDown, isTrue);
    expect(channel.mouseEvents[1].buttonDown, isFalse);
  });

  test('long press emits only a right click', () async {
    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    controller.onPointerUp(_up(const Offset(100, 100)), 0);

    expect(channel.mouseEvents, hasLength(2));
    expect(channel.mouseEvents[0].button, MouseButton.right.value);
    expect(channel.mouseEvents[0].buttonDown, isTrue);
    expect(channel.mouseEvents[1].button, MouseButton.right.value);
    expect(channel.mouseEvents[1].buttonDown, isFalse);
  });

  test('double tap emits two complete left clicks', () {
    _tap(controller, const Offset(100, 100));
    _tap(controller, const Offset(100, 100));

    expect(channel.mouseEvents.map((event) => event.buttonDown), [
      true,
      false,
      true,
      false,
    ]);
    expect(controller.leftButtonHeld, isFalse);
  });

  test('second tap movement holds left button until pointer up', () {
    _tap(controller, const Offset(100, 100));

    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    controller.onPointerMove(_move(const Offset(120, 110)), 1);
    controller.onPointerUp(_up(const Offset(120, 110)), 0);

    expect(channel.mouseEvents, hasLength(5));
    expect(channel.mouseEvents[2].button, MouseButton.left.value);
    expect(channel.mouseEvents[2].buttonDown, isTrue);
    expect(channel.mouseEvents[3].button, isNull);
    expect(channel.mouseEvents[4].button, MouseButton.left.value);
    expect(channel.mouseEvents[4].buttonDown, isFalse);
    expect(controller.leftButtonHeld, isFalse);
  });

  test('rapid taps at different positions do not start a drag', () {
    _tap(controller, const Offset(100, 100));

    controller.onPointerDown(_down(const Offset(250, 250)), 1);
    controller.onPointerMove(_move(const Offset(270, 260)), 1);
    controller.onPointerUp(_up(const Offset(270, 260)), 0);

    expect(channel.mouseEvents, hasLength(3));
    expect(channel.mouseEvents[2].button, isNull);
    expect(controller.leftButtonHeld, isFalse);
  });

  test('pointer cancellation releases an active drag', () {
    _tap(controller, const Offset(100, 100));
    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    controller.onPointerMove(_move(const Offset(120, 110)), 1);

    controller.onPointerCancel(0);

    expect(channel.mouseEvents.last.button, MouseButton.left.value);
    expect(channel.mouseEvents.last.buttonDown, isFalse);
    expect(controller.leftButtonHeld, isFalse);
  });

  test('pointer cancellation does not turn a pending tap into a click', () {
    controller.onPointerDown(_down(const Offset(100, 100)), 1);

    controller.onPointerCancel(0);

    expect(channel.mouseEvents, isEmpty);
  });

  test('adding a second pointer cancels drag without re-pressing left', () {
    _tap(controller, const Offset(100, 100));
    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    controller.onPointerMove(_move(const Offset(120, 110)), 1);

    controller.onPointerDown(_down(const Offset(200, 200), pointer: 2), 2);
    controller.onPointerUp(
      _up(const Offset(200, 200), pointer: 2),
      1,
      remainingPosition: const Offset(160, 130),
    );
    controller.onPointerMove(_move(const Offset(170, 130)), 1);

    expect(
      channel.mouseEvents.where((event) => event.buttonDown == true),
      hasLength(2),
    );
    expect(channel.mouseEvents.last.x, 550);
    expect(controller.leftButtonHeld, isFalse);
  });
  final contract = jsonDecode(
    File('../test/fixtures/mobile-gestures.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  for (final scenario in contract['dragCases'] as List) {
    test('shared explicit drag: ${scenario['name']}', () {
      var displayedActive = false;
      controller.onCursorMoved = () {
        displayedActive = controller.dragArmed || controller.leftButtonHeld;
      };
      for (final step in scenario['steps']) {
        switch (step['action']) {
          case 'toggle':
            controller.toggleDrag();
          case 'tap':
            _tap(controller, const Offset(100, 100));
          case 'swipe':
            final startX = controller.cursorX;
            controller.onPointerDown(_down(const Offset(100, 100)), 1);
            controller.onPointerMove(_move(const Offset(120, 100)), 1);
            expect(controller.cursorX, greaterThan(startX));
            controller.onPointerUp(_up(const Offset(120, 100)), 0);
          default:
            fail('Unknown drag action: ${step['action']}');
        }
        expect(controller.dragArmed || controller.leftButtonHeld, step['active']);
        expect(displayedActive, step['active']);
        expect(
          channel.mouseEvents
              .where((event) => event.buttonDown != null)
              .map((event) => event.buttonDown)
              .toList(),
          step['buttons'],
        );
      }
    });
  }
  for (final scenario in contract['cases'] as List) {
    test('shared gesture: ${scenario['name']}', () {
      Offset point(dynamic p) =>
          Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
      controller.setRemoteResolution(
        contract['remote'][0],
        contract['remote'][1],
      );
      controller.scale = (scenario['initialScale'] as num).toDouble();
      final a = point(scenario['start'][0]);
      final b = point(scenario['start'][1]);
      controller.onPointerDown(_down(a), 1);
      controller.onPointerDown(_down(b, pointer: 2), 2);
      controller.onTwoFingerStart(
        twoFingerCenterOf(a, b),
        twoFingerDistance(a, b),
      );
      for (final pair in scenario['moves']) {
        final a = point(pair[0]);
        final b = point(pair[1]);
        controller.onPointerMove(
          _move(a),
          2,
          twoFingerCenter: twoFingerCenterOf(a, b),
          twoFingerDistance: twoFingerDistance(a, b),
        );
      }
      expect(
        controller.scale,
        closeTo((scenario['scale'] as num).toDouble(), .001),
      );
      final wheel = channel.mouseEvents
          .where((e) => e.wheelDeltaX != null || e.wheelDeltaY != null)
          .toList();
      if (scenario['wheel'] == null) {
        expect(wheel, isEmpty);
      } else {
        expect(
          wheel.fold<double>(0, (sum, e) => sum + (e.wheelDeltaX ?? 0)),
          closeTo(scenario['wheel'][0], .001),
        );
        expect(
          wheel.fold<double>(0, (sum, e) => sum + (e.wheelDeltaY ?? 0)),
          closeTo(scenario['wheel'][1], .001),
        );
      }
      controller.onPointerUp(_up(b, pointer: 2), 1, remainingPosition: a);
      controller.onPointerUp(_up(a), 0);
      expect(channel.mouseEvents.where((e) => e.button != null), isEmpty);
    });
  }

  test('third finger cancels and suppresses survivors', () {
    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    controller.onPointerDown(_down(const Offset(200, 100), pointer: 2), 2);
    controller.onPointerDown(_down(const Offset(300, 100), pointer: 3), 3);
    controller.onPointerUp(_up(const Offset(300, 100), pointer: 3), 2);
    controller.onPointerUp(_up(const Offset(200, 100), pointer: 2), 1);
    controller.onPointerMove(_move(const Offset(140, 100)), 1);
    controller.onPointerUp(_up(const Offset(140, 100)), 0);
    expect(channel.mouseEvents, isEmpty);
    _tap(controller, const Offset(100, 100));
    expect(channel.mouseEvents, hasLength(2));
  });

  test('viewport change releases drag and does not click on lift', () {
    _tap(controller, const Offset(100, 100));
    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    controller.onPointerMove(_move(const Offset(130, 100)), 1);
    controller.setViewportSize(800, 400);
    expect(controller.leftButtonHeld, isFalse);
    final count = channel.mouseEvents.length;
    controller.onPointerUp(_up(const Offset(130, 100)), 0);
    expect(channel.mouseEvents.length, count);
  });

  test('zoom reduces cursor gain and resolution shrink clamps cursor', () {
    controller.scale = 2;
    controller.onPointerDown(_down(const Offset(100, 100)), 1);
    controller.onPointerMove(_move(const Offset(120, 100)), 1);
    expect(controller.cursorX, 525);
    controller.setRemoteResolution(200, 100);
    expect(controller.cursorX, 199);
    expect(controller.cursorY, 99);
  });

  test('letterbox pan is constrained to actual content', () {
    controller.setRemoteResolution(1920, 1080);
    controller.scale = 2;
    controller.translateY = 300;
    controller.setViewportSize(401, 800);
    expect(controller.translateY, 0);
  });
  testWidgets(
    'native sequential pointer moves scroll instead of accidental pinch',
    (tester) async {
      final router = TouchPointerRouter(controller);
      router.down(_down(const Offset(150, 400)));
      router.down(_down(const Offset(250, 400), pointer: 2));
      router.move(_move(const Offset(162, 400)));
      router.move(_move(const Offset(262, 400), pointer: 2));
      await tester.pump();
      expect(controller.scale, 1);
      expect(channel.mouseEvents.single.wheelDeltaX, 36);
      router.cancel();
    },
  );

  testWidgets(
    'stationary second finger can still pinch after coalesced frame',
    (tester) async {
      final router = TouchPointerRouter(controller);
      router.down(_down(const Offset(150, 400)));
      router.down(_down(const Offset(250, 400), pointer: 2));
      router.move(_move(const Offset(100, 400)));
      await tester.pump();
      expect(controller.scale, 1.5);
      expect(channel.mouseEvents, isEmpty);
      router.cancel();
    },
  );

  test(
    'accessible drag arms without pressing, swipe holds and lift releases',
    () {
      controller.toggleDrag();
      expect(controller.dragArmed, isTrue);
      expect(channel.mouseEvents, isEmpty);
      controller.onPointerDown(_down(const Offset(100, 100)), 1);
      controller.onPointerMove(_move(const Offset(120, 100)), 1);
      expect(controller.leftButtonHeld, isTrue);
      controller.onPointerUp(_up(const Offset(120, 100)), 0);
      expect(controller.leftButtonHeld, isFalse);
      expect(controller.dragArmed, isFalse);
      expect(channel.mouseEvents.first.buttonDown, isTrue);
      expect(channel.mouseEvents.last.buttonDown, isFalse);
    },
  );
  testWidgets(
    'native cancellation suppresses remaining fingers until all lift',
    (tester) async {
      final router = TouchPointerRouter(controller);
      router.down(_down(const Offset(150, 400)));
      router.down(_down(const Offset(250, 400), pointer: 2));
      router.cancelPointer(const PointerCancelEvent(pointer: 2));
      router.move(_move(const Offset(180, 400)));
      router.up(_up(const Offset(180, 400)));
      expect(channel.mouseEvents, isEmpty);
      router.down(_down(const Offset(150, 400)));
      router.up(_up(const Offset(150, 400)));
      expect(channel.mouseEvents, hasLength(2));
      router.cancel();
    },
  );

  // 默认 1000x800 远程画面装进 400x800 视口：
  // fitContain => Rect.fromLTWH(0, 240, 400, 320)，上下各有 240 黑边。
  group('direct touch mode', () {
    test('tap moves the cursor to the finger before clicking', () {
      controller.setDirectTouchMode(true);
      _tap(controller, const Offset(100, 400));

      expect(channel.mouseEvents, hasLength(3));
      final move = channel.mouseEvents[0];
      expect(move.button, isNull);
      expect(move.x, 250);
      expect(move.y, 400);
      expect(channel.mouseEvents[1].button, MouseButton.left.value);
      expect(channel.mouseEvents[1].buttonDown, isTrue);
      expect(channel.mouseEvents[1].x, 250);
      expect(channel.mouseEvents[1].y, 400);
      expect(channel.mouseEvents[2].buttonDown, isFalse);
      expect(controller.cursorX, 250);
      expect(controller.cursorY, 400);
    });

    test('finger position round-trips through the virtual cursor', () {
      controller.setDirectTouchMode(true);
      _tap(controller, const Offset(100, 400));

      final screen = controller.cursorScreenPosition();
      expect(screen, isNotNull);
      expect(screen!.dx, closeTo(100, .001));
      expect(screen.dy, closeTo(400, .001));
    });

    test('zoom and pan are applied when mapping the finger', () {
      controller.scale = 2;
      controller.setDirectTouchMode(true);
      _tap(controller, const Offset(300, 400));

      // local.x = 200 + (300 - 200) / 2 = 250 → 250/400*1000 = 625
      expect(channel.mouseEvents.first.x, 625);
      expect(channel.mouseEvents.first.y, 400);
      expect(controller.cursorX, 625);
    });

    test('letterbox taps clamp to the visible frame', () {
      controller.setDirectTouchMode(true);
      _tap(controller, const Offset(200, 10));

      expect(channel.mouseEvents.first.x, 500);
      expect(channel.mouseEvents.first.y, 0);
      expect(controller.cursorY, 0);
    });

    test('long press right-clicks at the finger position', () async {
      controller.setDirectTouchMode(true);
      controller.onPointerDown(_down(const Offset(100, 400)), 1);
      await Future<void>.delayed(const Duration(milliseconds: 550));
      controller.onPointerUp(_up(const Offset(100, 400)), 0);

      expect(channel.mouseEvents, hasLength(3));
      expect(channel.mouseEvents[1].button, MouseButton.right.value);
      expect(channel.mouseEvents[1].x, 250);
      expect(channel.mouseEvents[1].y, 400);
      expect(channel.mouseEvents[2].buttonDown, isFalse);
    });

    test('second-tap drag starts pressing at the finger position', () {
      controller.setDirectTouchMode(true);
      _tap(controller, const Offset(100, 400));
      channel.mouseEvents.clear();

      controller.onPointerDown(_down(const Offset(100, 400)), 1);
      controller.onPointerMove(_move(const Offset(120, 410)), 1);
      controller.onPointerUp(_up(const Offset(120, 410)), 0);

      expect(channel.mouseEvents.first.x, 250);
      expect(channel.mouseEvents[1].buttonDown, isTrue);
      expect(channel.mouseEvents[1].x, 250);
      expect(channel.mouseEvents.last.buttonDown, isFalse);
      expect(controller.leftButtonHeld, isFalse);
    });

    test('display origin is kept on the wire', () {
      controller.setRemoteDisplay(1000, 800, originX: 1920, originY: 100);
      controller.setDirectTouchMode(true);
      _tap(controller, const Offset(100, 400));

      expect(controller.cursorX, 250); // display-local
      expect(channel.mouseEvents.first.x, 2170);
      expect(channel.mouseEvents.first.y, 500);
    });

    test('turning direct touch off restores trackpad behaviour', () {
      controller.setDirectTouchMode(true);
      controller.setDirectTouchMode(false);
      channel.mouseEvents.clear();

      _tap(controller, const Offset(100, 400));

      expect(channel.mouseEvents, hasLength(2));
      expect(channel.mouseEvents[0].x, 500);
      expect(channel.mouseEvents[0].y, 400);
      expect(controller.cursorX, 500);
      expect(controller.cursorY, 400);
    });

    test('no remote resolution means no cursor jump', () {
      final fresh = TouchInputController(channel)
        ..setViewportSize(400, 800)
        ..setDirectTouchMode(true);
      addTearDown(fresh.dispose);
      _tap(fresh, const Offset(100, 400));

      expect(channel.mouseEvents, isEmpty);
      expect(fresh.cursorX, 0);
    });
  });

  // 放大后「拖动屏幕」：直接触摸模式改为 1:1 平移画面，
  // 轻点仍点哪点哪；触控板模式保持原来的拖光标 + 自动跟镜。
  // 400x400 视口装 1000x800 画面 => fitContain 为 (0, 40, 400, 320)，
  // scale=2 时水平可平移 ±200、垂直 ±120。
  group('zoomed direct touch pan', () {
    void zoomedSetup() {
      controller
        ..setViewportSize(400, 400)
        ..scale = 2
        ..setDirectTouchMode(true);
    }

    test('single-finger drag pans 1:1 without moving the remote mouse', () {
      zoomedSetup();
      var transforms = 0;
      controller.onTransformChanged = () => transforms++;
      final cursorX = controller.cursorX;
      final cursorY = controller.cursorY;

      controller.onPointerDown(_down(const Offset(200, 200)), 1);
      controller.onPointerMove(_move(const Offset(205, 202)), 1);
      expect(channel.mouseEvents, isEmpty);
      expect(controller.translateX, 0);

      // 阈值内被吞掉的小位移累计补回，保证跟手不丢距离。
      controller.onPointerMove(_move(const Offset(260, 240)), 1);
      expect(controller.translateX, 60);
      expect(controller.translateY, 40);
      controller.onPointerMove(_move(const Offset(270, 250)), 1);
      expect(controller.translateX, 70);
      expect(controller.translateY, 50);
      controller.onPointerUp(_up(const Offset(270, 250)), 0);

      expect(channel.mouseEvents, isEmpty);
      expect(controller.cursorX, cursorX);
      expect(controller.cursorY, cursorY);
      expect(controller.leftButtonHeld, isFalse);
      expect(transforms, greaterThan(0));
    });

    test('tap still clicks where the finger lands', () {
      zoomedSetup();
      _tap(controller, const Offset(300, 200));

      expect(channel.mouseEvents, hasLength(3));
      expect(channel.mouseEvents[0].button, isNull);
      expect(channel.mouseEvents[0].x, 625);
      expect(channel.mouseEvents[0].y, 400);
      expect(channel.mouseEvents[1].button, MouseButton.left.value);
      expect(channel.mouseEvents[1].buttonDown, isTrue);
      expect(channel.mouseEvents[1].x, 625);
      expect(controller.cursorX, 625);
    });

    test('pan is clamped to the zoomed content bounds', () {
      zoomedSetup();
      // 累计拖动 290px，超过 ±200 / ±120 的可平移范围。
      controller.onPointerDown(_down(const Offset(100, 100)), 1);
      controller.onPointerMove(_move(const Offset(390, 390)), 1);
      controller.onPointerUp(_up(const Offset(390, 390)), 0);

      expect(controller.translateX, 200);
      expect(controller.translateY, 120);
      expect(channel.mouseEvents, isEmpty);
    });

    test('consecutive pan gestures never hold the left button', () {
      zoomedSetup();
      _tap(controller, const Offset(200, 200));
      channel.mouseEvents.clear();

      // 300ms 内的第二次按下原本会被判成「双击后拖动」。
      controller.onPointerDown(_down(const Offset(200, 200)), 1);
      controller.onPointerMove(_move(const Offset(240, 210)), 1);
      controller.onPointerUp(_up(const Offset(240, 210)), 0);

      expect(controller.translateX, 40);
      expect(channel.mouseEvents, isEmpty);
      expect(controller.leftButtonHeld, isFalse);
    });

    test('explicit drag still holds the remote left button', () {
      zoomedSetup();
      controller.toggleDrag();
      controller.onPointerDown(_down(const Offset(200, 200)), 1);
      controller.onPointerMove(_move(const Offset(240, 210)), 1);

      expect(controller.leftButtonHeld, isTrue);
      expect(
        channel.mouseEvents.where((e) => e.buttonDown == true),
        hasLength(1),
      );
      expect(controller.translateX, isNot(40));
      controller.onPointerUp(_up(const Offset(240, 210)), 0);
      expect(controller.leftButtonHeld, isFalse);
    });

    test('long press right-clicks at the finger position', () async {
      zoomedSetup();
      controller.onPointerDown(_down(const Offset(300, 200)), 1);
      await Future<void>.delayed(const Duration(milliseconds: 550));
      controller.onPointerUp(_up(const Offset(300, 200)), 0);

      expect(channel.mouseEvents, hasLength(3));
      expect(channel.mouseEvents[0].x, 625);
      expect(channel.mouseEvents[1].button, MouseButton.right.value);
      expect(channel.mouseEvents[1].x, 625);
      expect(controller.translateX, 0);
    });

    test('zoom out restores cursor dragging', () {
      zoomedSetup();
      controller.onPointerDown(_down(const Offset(200, 200)), 1);
      controller.onPointerMove(_move(const Offset(230, 200)), 1);
      controller.onPointerUp(_up(const Offset(230, 200)), 0);
      expect(controller.translateX, 30);

      controller.resetZoom();
      channel.mouseEvents.clear();
      controller.onPointerDown(_down(const Offset(200, 200)), 1);
      controller.onPointerMove(_move(const Offset(240, 200)), 1);
      controller.onPointerUp(_up(const Offset(240, 200)), 0);

      expect(controller.scale, 1);
      expect(controller.translateX, 0);
      expect(controller.cursorX, greaterThan(500));
      expect(channel.mouseEvents.last.button, isNull);
    });

    test('trackpad mode keeps moving the cursor when zoomed', () {
      controller
        ..setViewportSize(400, 400)
        ..scale = 2;
      controller.onPointerDown(_down(const Offset(200, 200)), 1);
      controller.onPointerMove(_move(const Offset(240, 200)), 1);
      controller.onPointerUp(_up(const Offset(240, 200)), 0);

      expect(controller.cursorX, greaterThan(500));
      expect(controller.translateX, 0);
      expect(channel.mouseEvents.last.button, isNull);
    });
  });
}
