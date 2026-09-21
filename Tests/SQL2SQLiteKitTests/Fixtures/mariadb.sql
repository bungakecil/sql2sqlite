DROP TABLE IF EXISTS `events`;
CREATE TABLE `events` (
  `id` int NOT NULL AUTO_INCREMENT,
  `title` varchar(100) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp(6) ON UPDATE current_timestamp(6),
  `event_date` date DEFAULT (curdate()),
  `tracking_id` char(36) DEFAULT (uuid()),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `events` VALUES (1,'Conference','2026-09-22 00:00:00','2026-09-22 00:00:00.123456','2026-09-22','11111111-1111-1111-1111-111111111111');
INSERT INTO `events` VALUES (2,'Workshop','2026-09-23 00:00:00','2026-09-23 00:00:00.654321','2026-09-23','22222222-2222-2222-2222-222222222222');
INSERT INTO `events` VALUES (3,'Meetup','2026-09-24 00:00:00','2026-09-24 00:00:00.000000','2026-09-24','33333333-3333-3333-3333-333333333333');
