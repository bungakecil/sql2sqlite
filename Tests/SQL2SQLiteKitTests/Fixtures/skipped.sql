DROP TABLE IF EXISTS `docs`;
CREATE TABLE `docs` (
  `id` int NOT NULL AUTO_INCREMENT,
  `body` text,
  `place` varchar(64) DEFAULT NULL,
  PRIMARY KEY (`id`),
  FULLTEXT KEY `ft_body` (`body`),
  KEY `k_place` (`place`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO `docs` VALUES (1,'hello world','here'),(2,'goodbye world','there');

DROP TABLE IF EXISTS `shapes`;
CREATE TABLE `shapes` (
  `id` int NOT NULL,
  `label` varchar(32) DEFAULT NULL,
  PRIMARY KEY (`id`),
  SPATIAL KEY `sp_label` (`label`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO `shapes` VALUES (1,'square');

DELIMITER ;;
CREATE DEFINER=`root`@`localhost` TRIGGER `docs_audit` BEFORE INSERT ON `docs` FOR EACH ROW BEGIN
  SET @count = @count + 1;
  SET NEW.place = COALESCE(NEW.place, 'unknown');
END ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `count_docs`()
BEGIN
  SELECT COUNT(*) FROM `docs`;
END ;;
CREATE DEFINER=`root`@`localhost` FUNCTION `double_it`(n INT) RETURNS int
DETERMINISTIC
BEGIN
  RETURN n * 2;
END ;;
CREATE DEFINER=`root`@`localhost` EVENT `nightly` ON SCHEDULE EVERY 1 DAY DO
BEGIN
  DELETE FROM `docs` WHERE `id` < 0;
END ;;
DELIMITER ;

INSERT INTO `docs` VALUES (3,'after the routines','elsewhere');
