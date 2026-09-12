import 'package:flutter/material.dart';
import 'package:hercycle/core/app_theme.dart';

class Article {
  final String title;
  final String description;
  final String content;
  final String category;

  const Article({
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
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: context.her.ink),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.her.muted.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                article.description,
                style: TextStyle(fontSize: 16, fontStyle: FontStyle.italic, color: context.her.ink),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              article.content,
              style: TextStyle(fontSize: 16, height: 1.6, color: context.her.ink),
            ),
          ],
        ),
      ),
    );
  }
}
