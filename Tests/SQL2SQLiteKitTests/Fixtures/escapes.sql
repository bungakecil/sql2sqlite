DROP TABLE IF EXISTS `escapes`;
CREATE TABLE `escapes` (
  `id` int NOT NULL AUTO_INCREMENT,
  `v` text,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO `escapes` VALUES
 (1,'it\'s; complicated'),
 (2,'doubled '' quote'),
 (3,'back\\slash'),
 (4,'say \"hi\"'),
 (5,'nul\0byte'),
 (6,'ctrl\Zsub'),
 (7,'tab\there'),
 (8,'nl\nbreak'),
 (9,'cr\rreturn'),
 (10,'like\%pattern'),
 (11,'under\_score'),
 (12,'semi;colon'),
 (13,'-- not a comment'),
 (14,'/* not a comment */'),
 (15,'# not a comment');
