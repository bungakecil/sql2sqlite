DROP TABLE IF EXISTS `authors`;
CREATE TABLE `authors` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `name` varchar(255) COLLATE utf8mb4_general_ci NOT NULL,
  `handle` varchar(64) COLLATE utf8mb4_bin DEFAULT NULL,
  `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `by_name` (`name`(10)),
  UNIQUE KEY `uq_handle` (`handle`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4;
INSERT INTO `authors` VALUES
 (1,'Ada Lovelace','ada','2020-01-01 00:00:00','2020-01-01 00:00:00'),
 (2,'Alan Turing','alan','2020-01-02 00:00:00','2020-01-02 00:00:00');

DROP TABLE IF EXISTS `articles`;
CREATE TABLE `articles` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `author_id` int unsigned DEFAULT NULL,
  `title` varchar(255) NOT NULL,
  `body` mediumtext,
  `status` enum('draft','review','published') NOT NULL DEFAULT 'draft',
  `tags` set('swift','sqlite','mysql') DEFAULT NULL,
  `word_count` int NOT NULL DEFAULT '0',
  `double_count` int GENERATED ALWAYS AS (`word_count` * 2) STORED,
  PRIMARY KEY (`id`),
  KEY `by_name` (`title`),
  CONSTRAINT `fk_author` FOREIGN KEY (`author_id`) REFERENCES `authors` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO `articles` (`id`, `author_id`, `title`, `body`, `status`, `tags`, `word_count`) VALUES
 (1,1,'On Engines','The analytical engine.','published','swift,sqlite',3),
 (2,2,'On Machines','Can machines think?','review','mysql',4),
 (3,NULL,'Orphan','No author.','draft',NULL,2);

DROP TABLE IF EXISTS `article_stats`;
CREATE TABLE `article_stats` (
  `article_id` int unsigned NOT NULL,
  `day` date NOT NULL,
  `views` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`article_id`,`day`),
  KEY `by_name` (`day`),
  CONSTRAINT `fk_article` FOREIGN KEY (`article_id`) REFERENCES `articles` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO `article_stats` VALUES (1,'2020-03-01',10),(1,'2020-03-02',20),(2,'2020-03-01',5);
