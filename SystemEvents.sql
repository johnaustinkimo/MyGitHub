/*M!999999\- enable the sandbox mode */ 
-- MariaDB dump 10.19  Distrib 10.11.18-MariaDB, for Linux (x86_64)
--
-- Host: localhost    Database: Syslog
-- ------------------------------------------------------
-- Server version	10.11.18-MariaDB

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `SystemEvents`
--

DROP TABLE IF EXISTS `SystemEvents`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `SystemEvents` (
  `ID` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `CustomerID` bigint(20) DEFAULT NULL,
  `ReceivedAt` datetime DEFAULT NULL,
  `DeviceReportedTime` datetime DEFAULT NULL,
  `Facility` smallint(6) DEFAULT NULL,
  `Priority` smallint(6) DEFAULT NULL,
  `FromHost` varchar(60) DEFAULT NULL,
  `Message` text DEFAULT NULL,
  `NTSeverity` int(11) DEFAULT NULL,
  `Importance` int(11) DEFAULT NULL,
  `EventSource` varchar(60) DEFAULT NULL,
  `EventUser` varchar(60) DEFAULT NULL,
  `EventCategory` int(11) DEFAULT NULL,
  `EventID` int(11) DEFAULT NULL,
  `EventBinaryData` mediumtext DEFAULT NULL,
  `MaxAvailable` int(11) DEFAULT NULL,
  `CurrUsage` int(11) DEFAULT NULL,
  `MinUsage` int(11) DEFAULT NULL,
  `MaxUsage` int(11) DEFAULT NULL,
  `InfoUnitID` int(11) DEFAULT NULL,
  `SysLogTag` varchar(60) DEFAULT NULL,
  `ProcessID` varchar(60) NOT NULL DEFAULT '',
  `EventLogType` varchar(60) DEFAULT NULL,
  `GenericFileName` varchar(60) DEFAULT NULL,
  `SystemID` int(11) DEFAULT NULL,
  `Checksum` int(11) unsigned NOT NULL DEFAULT 0,
  `OprReportedTime` datetime DEFAULT NULL,
  `OprReported` varchar(1) DEFAULT 'N',
  `OprNameID` varchar(60) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  KEY `idx_SystemEvents_OprReported` (`OprReported`)
) ENGINE=InnoDB AUTO_INCREMENT=77 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `SystemEvents`
--

LOCK TABLES `SystemEvents` WRITE;
/*!40000 ALTER TABLE `SystemEvents` DISABLE KEYS */;
INSERT INTO `SystemEvents` VALUES
(1,NULL,'2026-09-01 16:21:28','2026-09-01 16:21:28',16,4,'rwa01','SELINUX RSYSLOG MYSQL TEST rwa01.taifex.com.tw 2026-09-01T16:21:28+08:00',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427095]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(2,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=WORKER_STOP version=3.9.2 worker=1',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[420440]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(3,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=WORKER_STOP version=3.9.2 worker=4',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[420440]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(4,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=WORKER_STOP version=3.9.2 worker=3',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[420440]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(5,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=WORKER_STOP version=3.9.2 worker=2',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[420440]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(6,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=STOP version=3.9.2',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[420440]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(7,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=FILTER_LOAD version=3.10 source=builtin-defaults file=/etc/tg_https_proxy.filters filters=6',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(8,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=3128 label=system_testing1',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(9,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9966 label=psrvmon01',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(10,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9911 label=system_status_testing',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(11,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9666 label=DBA',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(12,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=5151 label=vmware',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(13,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9110 label=statsmon_testing',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(14,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9111 label=statsmon',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(15,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9210 label=statsmon_testing_2',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(16,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9211 label=statsmon_2',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(17,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9310 label=statsmon_dev',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(18,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9311 label=statsmon_dev_2',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(19,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9410 label=statsmon_batch_testing',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(20,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9411 label=statsmon_batch_dev',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(21,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9412 label=statsmon_batch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(22,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9510 label=statsmon_ops_testing',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(23,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9511 label=statsmon_ops_dev',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(24,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9512 label=statsmon_ops',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(25,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9513 label=statsmon_ops_oa',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(26,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9514 label=statsmon_debug',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(27,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9515 label=ccp_prod',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(28,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9212 label=statsmon_oa_2',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(29,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9611 label=bq_informatica',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(30,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9612 label=bq_informatica_testing',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(31,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9711 label=tc_informatica',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(32,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9712 label=tc_informatica_testing',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(33,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9797 label=earthquake',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(34,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9162 label=traps',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(35,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9601 label=gpm_dev',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(36,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9602 label=gpm_prd',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(37,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9696 label=prodev',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(38,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9697 label=prodevlte',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(39,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9888 label=sim',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(40,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9788 label=reuters',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(41,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=443 label=telegram_api',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(42,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9328 label=bsrvmona1',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(43,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9428 label=nsrvmona1',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(44,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9487 label=network',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(45,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9488 label=network_oa',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(46,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9527 label=xy',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(47,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9528 label=bq',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(48,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9529 label=tfx-srvmgt01',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(49,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9628 label=nsrvmon01',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(50,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9728 label=bq_tfx-logsrva1',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(51,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9729 label=bq_tfx-logsrv',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(52,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9955 label=prtg_prod',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(53,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9988 label=pms',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(54,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9119 label=CriticalAlert',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(55,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9559 label=operator',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(56,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=LISTEN version=3.10 address=0.0.0.0 port=9922 label=soar',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(57,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=WORKER_START version=3.10 worker=2',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(58,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=WORKER_START version=3.10 worker=3',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(59,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=WORKER_START version=3.10 worker=1',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(60,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=START version=3.10 mode=persistent-queue listeners=49 workers=4 spool=/var/lib/tg_https_proxy/spool sensitive_audit=enabled access=allow-all channel_max_per_minute=20 max_pending=10000 max_failed=10000 max_spool_bytes=10737418240 delivery_semantics=at_least_once',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(61,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,4,'rwa01','event=AUDIT_WARNING version=3.10 sensitive_audit=enabled warning=token-chat-message-and-image-content-are-logged',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(62,NULL,'2026-09-01 16:35:41','2026-09-01 16:35:41',3,5,'rwa01','event=WORKER_START version=3.10 worker=4',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(63,NULL,'2026-09-01 16:36:37','2026-09-01 16:36:37',3,6,'rwa01','event=RAW_DATA_RECEIVED version=3.10 client_ip=192.168.166.232 client_port=59210 listen_port=9911 label=system_status_testing endpoint=/sendMessage content_type=text/plain; charset=utf-8 filename= bytes=5',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(64,NULL,'2026-09-01 16:36:37','2026-09-01 16:36:37',3,6,'rwa01','event=RAW_DATA_ENQUEUED version=3.10 job_id=1788251797584-427476-90b2c51b6e1e868de07e3c618e667d7a client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage bytes=5 durability=durable',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(65,NULL,'2026-09-01 16:36:37','2026-09-01 16:36:37',3,5,'rwa01','event=AUDIT_CREDENTIAL version=3.10 job_id=1788251797584-427476-90b2c51b6e1e868de07e3c618e667d7a client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage bot_token=\"8616293891:AAGVuGhH_8C-FJBk7kMpVOeUlClWAbbJ9QY\" chat_id=\"-1001375434671\"',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(66,NULL,'2026-09-01 16:36:37','2026-09-01 16:36:37',3,5,'rwa01','event=AUDIT_TEXT version=3.10 job_id=1788251797584-427476-90b2c51b6e1e868de07e3c618e667d7a client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage field=message_text seq=1 total=1 raw_bytes=5 value=\"test\\n\"',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(67,NULL,'2026-09-01 16:36:37','2026-09-01 16:36:37',3,5,'rwa01','test',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,'2026-09-02 11:38:43','Y','jeffreyhu'),
(68,NULL,'2026-09-01 16:36:37','2026-09-01 16:36:37',3,6,'rwa01','event=JOB_DEQUEUE version=3.10 worker=4 job_id=1788251797584-427476-90b2c51b6e1e868de07e3c618e667d7a client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage attempt=1',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(69,NULL,'2026-09-01 16:36:38','2026-09-01 16:36:38',3,6,'rwa01','event=JOB_SENT version=3.10 worker=4 job_id=1788251797584-427476-90b2c51b6e1e868de07e3c618e667d7a client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage attempt=1 telegram_http=200 response_bytes=346',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(70,NULL,'2026-09-02 09:39:27','2026-09-02 09:39:27',3,6,'rwa01','event=RAW_DATA_RECEIVED version=3.10 client_ip=192.168.166.232 client_port=34468 listen_port=9911 label=system_status_testing endpoint=/sendMessage content_type=text/plain; charset=utf-8 filename= bytes=18',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(71,NULL,'2026-09-02 09:39:27','2026-09-02 09:39:27',3,6,'rwa01','event=RAW_DATA_ENQUEUED version=3.10 job_id=1788313167681-427476-a07df1ebee214dc6868b48d2c5449a62 client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage bytes=18 durability=durable',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(72,NULL,'2026-09-02 09:39:27','2026-09-02 09:39:27',3,5,'rwa01','event=AUDIT_CREDENTIAL version=3.10 job_id=1788313167681-427476-a07df1ebee214dc6868b48d2c5449a62 client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage bot_token=\"8616293891:AAGVuGhH_8C-FJBk7kMpVOeUlClWAbbJ9QY\" chat_id=\"-1001375434671\"',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(73,NULL,'2026-09-02 09:39:27','2026-09-02 09:39:27',3,5,'rwa01','event=AUDIT_TEXT version=3.10 job_id=1788313167681-427476-a07df1ebee214dc6868b48d2c5449a62 client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage field=message_text seq=1 total=1 raw_bytes=18 value=\"test from 110.121\\n\"',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(74,NULL,'2026-09-02 09:39:27','2026-09-02 09:39:27',3,5,'rwa01','test from 110.121',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,'2026-09-02 10:09:02','Y','jeffreyhu'),
(75,NULL,'2026-09-02 09:39:27','2026-09-02 09:39:27',3,6,'rwa01','event=JOB_DEQUEUE version=3.10 worker=3 job_id=1788313167681-427476-a07df1ebee214dc6868b48d2c5449a62 client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage attempt=1',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL),
(76,NULL,'2026-09-02 09:39:29','2026-09-02 09:39:29',3,6,'rwa01','event=JOB_SENT version=3.10 worker=3 job_id=1788313167681-427476-a07df1ebee214dc6868b48d2c5449a62 client_ip=192.168.166.232 listen_port=9911 label=system_status_testing endpoint=/sendMessage attempt=1 telegram_http=200 response_bytes=359',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,'tg_https_proxy[427476]:','',NULL,NULL,NULL,0,NULL,'N',NULL);
/*!40000 ALTER TABLE `SystemEvents` ENABLE KEYS */;
UNLOCK TABLES;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-09-02 12:08:46
