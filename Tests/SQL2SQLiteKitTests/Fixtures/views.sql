DROP TABLE IF EXISTS `posts`;
CREATE TABLE `posts` (
  `id` int NOT NULL,
  `title` varchar(100) NOT NULL,
  `active` tinyint(1) NOT NULL DEFAULT '1',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO `posts` VALUES (1,'first',1),(2,'second',0),(3,'third',1);

--
-- Temporary view structure for view `active_posts`
--
DROP TABLE IF EXISTS `active_posts`;
/*!50001 DROP VIEW IF EXISTS `active_posts`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `active_posts` AS SELECT
 1 AS `id`,
 1 AS `title`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `active_titles`
--
DROP TABLE IF EXISTS `active_titles`;
/*!50001 DROP VIEW IF EXISTS `active_titles`*/;
/*!50001 CREATE VIEW `active_titles` AS SELECT
 1 AS `title`*/;

--
-- Final view definition for `active_titles`, which depends on `active_posts`
-- and is deliberately declared first to exercise the retry pass.
--
/*!50001 DROP VIEW IF EXISTS `active_titles`*/;
/*!50001 CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `active_titles` AS select `active_posts`.`title` AS `title` from `active_posts` */;

--
-- Final view definition for `active_posts`
--
/*!50001 DROP VIEW IF EXISTS `active_posts`*/;
/*!50001 CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `active_posts` AS select `p`.`id` AS `id`,`p`.`title` AS `title` from `posts` `p` where (`p`.`active` = 1) */;
