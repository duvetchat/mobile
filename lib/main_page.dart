import 'package:flutter/material.dart';

class MainPage extends StatelessWidget {
  const MainPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF36393F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF36393F),
        elevation: 1,
        title: const Text(
          '# general-sexo',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        actions: const [
          Icon(Icons.search, color: Colors.grey),
          SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                _ChatMessage(
                  avatar: 'U',
                  username: 'UserOne',
                  content: 'Hey everyone!',
                ),
                _ChatMessage(
                  avatar: 'B',
                  username: 'Bot',
                  content: 'Hello, welcome to the server.',
                  isBot: true,
                ),
              ],
            ),
          ),
          // Input area
          Container(
            color: const Color(0xFF40444B),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Expanded(
                  child: TextField(
                    style: TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Message #general',
                      hintStyle: TextStyle(color: Colors.grey),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.grey),
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatMessage extends StatelessWidget {
  final String avatar;
  final String username;
  final String content;
  final bool isBot;
  const _ChatMessage({
    required this.avatar,
    required this.username,
    required this.content,
    this.isBot = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: Colors.blue,
            radius: 18,
            child: Text(
              avatar,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: username,
                        style: TextStyle(
                          color: isBot ? Colors.cyanAccent : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
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
                const SizedBox(height: 4),
                Text(content, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
