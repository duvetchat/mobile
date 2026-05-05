import 'package:flutter/material.dart';
import 'dart:core';
import 'panels.dart';

import 'left_page.dart';
import 'main_page.dart';
import 'right_page.dart';

void main() => runApp(const DuvetApp());

class DuvetApp extends StatelessWidget {
  const DuvetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: MyApp());
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        OverlappingPanels(
          left: Builder(builder: (context) => const LeftPage()),
          right: Builder(
            builder: (context) {
              // Get the restWidth from OverlappingPanels
              final state = OverlappingPanels.of(context);
              final restWidth = state?.widget.restWidth ?? 40;

              return Align(
                alignment: Alignment.centerRight, // stick to the right edge
                child: SizedBox(
                  width:
                      MediaQuery.of(context).size.width -
                      restWidth, // covers the reveal area
                  child: const RightPage(),
                ),
              );
            },
          ),
          main: Builder(builder: (context) => const MainPage()),
          onSideChange: (side) {
            setState(() {
              // handle side change
            });
          },
        ),
      ],
    );
  }
}
