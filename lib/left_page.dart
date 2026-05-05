import 'package:flutter/material.dart';

class _GuildIcon extends StatelessWidget {
  final String initial;
  final Color color;
  const _GuildIcon({required this.initial, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: CircleAvatar(
        backgroundColor: color,
        radius: 24,
        child: Text(
          initial,
          style: const TextStyle(color: Colors.white, fontSize: 20),
        ),
      ),
    );
  }
}

class LeftPage extends StatelessWidget {
  const LeftPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      // ← Wrap everything in Material
      color: Colors.transparent, // or use Color(0xFF202225)
      child: Row(
        children: [
          // Guild icons
          Container(
            width: 72,
            color: const Color(0xFF202225),
            child: ListView(
              children: const [
                _GuildIcon(initial: 'G', color: Colors.blue),
                _GuildIcon(initial: 'S', color: Colors.green),
                _GuildIcon(initial: 'F', color: Colors.orange),
              ],
            ),
          ),
          // Channel list
          Expanded(
            child: Container(
              color: const Color(0xFF2F3136),
              child: ListView(
                padding: const EdgeInsets.all(8),
                children: const [
                  Text(
                    'TEXT CHANNELS',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  ListTile(
                    leading: Icon(Icons.tag, color: Colors.grey, size: 18),
                    title: Text(
                      'general',
                      style: TextStyle(color: Colors.white),
                    ),
                    dense: true,
                  ),
                  ListTile(
                    leading: Icon(Icons.tag, color: Colors.grey, size: 18),
                    title: Text(
                      'random',
                      style: TextStyle(color: Colors.white),
                    ),
                    dense: true,
                  ),
                  Divider(color: Colors.white24),
                  Text(
                    'VOICE CHANNELS',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.volume_up,
                      color: Colors.grey,
                      size: 18,
                    ),
                    title: Text(
                      'General',
                      style: TextStyle(color: Colors.white),
                    ),
                    dense: true,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
