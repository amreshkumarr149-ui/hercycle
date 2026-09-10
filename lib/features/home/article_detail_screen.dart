import 'package:flutter/material.dart';

class Article {
  final String title;
  final String description;
  final String content;
  final String category;

  Article({
    required this.title,
    required this.description,
    required this.content,
    required this.category,
  });
}

class ArticleDetailScreen extends StatelessWidget {
  final Article article;
  const ArticleDetailScreen({super.key, required this.article});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(article.category, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              article.title,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A)),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF9C8D2).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                article.description,
                style: const TextStyle(fontSize: 16, fontStyle: FontStyle.italic, color: Color(0xFF7A4A54)),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              article.content,
              style: const TextStyle(fontSize: 16, height: 1.6, color: Color(0xFF4A4A4A)),
            ),
          ],
        ),
      ),
    );
  }
}
