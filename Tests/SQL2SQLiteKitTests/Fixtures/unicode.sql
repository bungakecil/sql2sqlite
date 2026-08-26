DROP TABLE IF EXISTS `unicode`;
CREATE TABLE `unicode` (
  `id` int NOT NULL,
  `v` text,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO `unicode` VALUES
 (1,'日本語テキスト'),
 (2,'family 👨‍👩‍👧‍👦 zwj'),
 (3,'combining é vs é'),
 (4,'مرحبا بالعالم'),
 (5,'mixed 日本 👍 عربى end');
