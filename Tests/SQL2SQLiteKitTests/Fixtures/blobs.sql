DROP TABLE IF EXISTS `blobs`;
CREATE TABLE `blobs` (
  `id` int NOT NULL,
  `b` longblob,
  `vb` varbinary(64),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB;
INSERT INTO `blobs` VALUES
 (1,_binary 'AB',_binary 'ab'),
 (2,0x48656C6C6F,X'4869'),
 (3,_binary 'nul\0inside',0x00FF00),
 (4,_binary '',0x),
 (5,NULL,NULL);
