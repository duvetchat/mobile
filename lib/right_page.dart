import 'package:flutter/material.dart';

enum Status { online, offline }

class _UserTile extends StatelessWidget {
  final String name;
  final Status status;
  final bool isBot;
  const _UserTile({
    required this.name,
    required this.status,
    this.isBot = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: Colors.blue,
            radius: 16,
            child: Text(
              name[0],
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: status == Status.online ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF2F3136), width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: name,
              style: const TextStyle(color: Colors.white),
            ),
            if (isBot)
              const TextSpan(
                text: '  BOT',
                style: TextStyle(
                  color: Colors.blueGrey,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class RightPage extends StatelessWidget {
  const RightPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        color: const Color(0xFF2F3136), // no width!, now fills parent
        child: ListView(
          padding: const EdgeInsets.all(8),
          children: const [
            Text(
              'ONLINE — 3',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            _UserTile(name: 'UserOne', status: Status.online),
            _UserTile(name: 'CoolDev', status: Status.online),
            _UserTile(name: 'Bot', status: Status.online, isBot: true),
            Divider(color: Colors.white24),
            Text(
              'OFFLINE — 1',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            _UserTile(name: 'AwayGuy', status: Status.offline),
          ],
        ),
      ),
    );
  }
}
