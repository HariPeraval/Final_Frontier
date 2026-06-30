SET doc off
SET feedback off
SET SERVEROUTPUT ON SIZE 1000000
WHENEVER SQLERROR EXIT FAILURE;
WHENEVER OSERROR EXIT FAILURE;

/********************************************************************/
/*  FILENAME:     zms_tpe_pre_process.sql                           */
/*                                                                  */
/*  DESCRIPTION:  This process updates all IMS inactive transaction */
/*                types coming from TPE as skipped.                 */
/*                                                                  */
/*  PARAMETERS:                                                     */
/*                                                                  */
/*  RESTART LOGIC:  Program is fully restartable.                   */
/*                                                                  */
/*  CHANGE HISTORY: m schmidt   Added check_activity                */
/*                                                                  */
/********************************************************************/
/* Hari - Mark all Akron KJO Shipment transaction types Skip            */
---------------------------------------------------------------------------------
-- GLOBAL VARIABLE DECLARATIONS
---------------------------------------------------------------------------------

DECLARE

  INIT_LOG_FAIL       EXCEPTION;
  CLOSE_LOG_FAIL      EXCEPTION;
  CURSOR_FAIL         EXCEPTION;
  FAILED_PROC         EXCEPTION;
  g_batch_date        DATE;
  g_debug_lvl         NUMBER := 1;
  g_tot_insert_cnt    NUMBER := 0;
  g_tot_update_cnt    NUMBER := 0;
  g_return_code       NUMBER := 0;
  g_missing_count     NUMBER := 0;
  g_threshold_minutes NUMBER := 0;
  g_total_run_time    NUMBER := 0;
  g_err_msg           VARCHAR2(500) := NULL;
  g_mesg              VARCHAR2(500) := NULL;
  g_subj              VARCHAR2(500) := NULL;
  g_database          VARCHAR2(10) := NULL;
  g_tran_date         DATE;
  g_store             NUMBER;
  g_item              zms_ifi_sa_sales.item%TYPE;
  g_last_process_time DATE;
  g_start_run_time        DATE;
  g_end_run_time      DATE;
  g_retry_flag        VARCHAR2(1) := '&&1';
  g_rec_count         NUMBER := 0;
  c_program           CONSTANT VARCHAR2(30) := 'zms_tpe_pre_process.sql';

---------------------------------------------------------------------------------
-- GLOBAL CURSOR DECLARATIONS
---------------------------------------------------------------------------------

---------------------------------------------------------------------------------
-- GLOBAL STRUCTURES
---------------------------------------------------------------------------------

---------------------------------------------------------------------------------
-- PROCEDURES/FUNCTIONS
---------------------------------------------------------------------------------

---------------------------------------------------------------------------------
-- Mark Transactions
---------------------------------------------------------------------------------
PROCEDURE mark_transactions(o_rc IN OUT NUMBER, o_err_msg IN OUT VARCHAR2) IS

  l_line_count NUMBER := 0;
  l_procname VARCHAR2(30) := 'mark_invalid_data';

BEGIN

  zlog.write_msg(1, 'Started ' || l_procname);

------------------------------------------------
-- Mark all non-active IMS transaction types
-- to skip.
------------------------------------------------

  UPDATE zms_ifi_ims_tran_data i
     SET i.process_status = 'X',
         i.process_date = sysdate,
         i.error_message = 'Skip inactive transaction type'
   WHERE i.transaction_type NOT IN (SELECT ims_tran_type from zms_ims_tran_code_xref where active_flag = 'Y')
     AND i.process_status = 'N'
	 and i.on_hand_transaction_qty < 0;

  zlog.write_msg(1, 'Marked ' || SQL%ROWCOUNT || ' inactive transaction types');

  COMMIT;
 
------------------------------------------------
-- Hari - Mark all Akron KJO Shipment transaction types 
-- to skip.
------------------------------------------------

  UPDATE zms_ifi_ims_tran_data i
     SET i.process_status = 'X',
         i.process_date = sysdate,
         i.error_message = 'Skip Akron KJO Shipment transaction types'
   WHERE i.transaction_type IN (select IMS_TRAN_TYPE from zms.zms_kjo_loc_restriction where active_flag = 'Y')
     AND i.process_status = 'N'
     AND Exists (Select 1 
                   from zms.zms_kjo_loc_restriction e 
                  where e.ims_tran_type=i.transaction_type
                    and e.source_destination='SOURCE'
                    and e.tran_category='SHIP'
                    and e.active_flag = 'Y'
                    and e.location=zms_ims_to_rms_loc_fnc(i.LOCATION,i.sku) ); 

  zlog.write_msg(1, 'Marked ' || SQL%ROWCOUNT || ' inactive Akron KJO Shipment transaction types');

  COMMIT; 

------------------------------------------------
-- Mark all non-KJO skus.
------------------------------------------------

  UPDATE zms_ifi_ims_tran_data i
     SET i.process_status = 'E-BRAND',
         i.process_date = sysdate,
         i.error_message = 'SKU is not a KJO brand in RMS'
   WHERE i.process_status = 'N'
     AND EXISTS (SELECT 'x'
                   FROM pid_sku_master p
                  WHERE i.sku = p.sku
                    AND p.initiated_brand NOT IN (SELECT sig_brand FROM pid_atel_brand_xref x WHERE x.campus = 'Akron'));

  zlog.write_msg(1, 'Marked ' || SQL%ROWCOUNT || ' SKUs that are not a KJO brand in RMS');

  COMMIT;

------------------------------------------------
-- If the retry flag was set to R then update all
-- transactions that were previously in error to
-- N so that they can be retried.
------------------------------------------------

  IF ((NVL(g_retry_flag, 'X') = 'R')) 
  THEN

    UPDATE zms_ifi_ims_tran_data i
       SET i.process_status = 'N',
           i.process_date = NULL,
           i.error_message = NULL
     WHERE SUBSTR(i.process_status, 1, 1) = 'E'
       AND i.process_status NOT IN ('E-BRAND');

    zlog.write_msg(1, 'Marked ' || SQL%ROWCOUNT || ' ims stage error records to be re-processed');

    COMMIT;

    UPDATE zms_ifi_ims_sales
       SET process_status = 'N',
           processed_date = NULL,
           error_message = NULL
     WHERE process_status = 'E';

    zlog.write_msg(1, 'Marked ' || SQL%ROWCOUNT || ' ims sales error records to be re-processed');

    COMMIT;

    SELECT count(*)
      INTO g_missing_count
      FROM (SELECT v.staging_id
              FROM (SELECT rownum STAGING_ID
                      FROM (SELECT staging_id FROM zms_ifi_ims_tran_data
                            UNION ALL
                            SELECT staging_id FROM zms_ifi_ims_tran_data) v1
                     MINUS 
                    SELECT /*+ parallel(a,8) */ a.staging_id 
                      FROM zms_ifi_ims_tran_data a) v
     WHERE v.staging_id < (SELECT max(staging_id) MAX_STAGING_ID FROM zms_ifi_ims_tran_data WHERE insert_date < (sysdate - 240/1440))  -- Let staging IDs settle for 4 hours
       AND v.staging_id > (SELECT max(staging_id) MIN_STAGING_ID FROM zms_ifi_ims_tran_data WHERE TO_NUMBER(workflow_run_id) = 2));    -- Skip Go live night workflows

    IF (g_missing_count > 0)
    THEN

      SELECT name INTO g_database from v$database;

      g_mesg := 'Contact IMS/ESI team.  There are ' || g_missing_count || ' missing TPE staging IDs in zms_ifi_ims_tran_data.';
      g_subj := 'WARNING(' || g_database || '):  TPE Staging IDs missing';

      pid_email_pkg.mail(sender      => 'support <noreply@zalecorp.com>'
                         ,recipients => '"ITMerchandisingDallas"<ITMerchandisingDallas@signetjewelers.com>'
                         ,subject    => g_subj
                         ,message    => g_mesg);

      zlog.write_msg(1, 'Sent email - sqlcode=' || sqlcode);
      zlog.write_msg(0, 'WARNING:  Missing ' || g_missing_count || ' TPE staging IDs in zms_ifi_ims_tran_data');

    ELSE
      zlog.write_msg(0, 'No missing TPE staging IDs');
    END IF;

  END IF;

  o_rc := 0;

EXCEPTION

  WHEN OTHERS THEN

    o_rc := sqlcode;
    o_err_msg := sqlerrm;
    zlog.write_error('Procedure ' || l_procname || ' failed to mark inactive transactions or setup retry');
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    ROLLBACK;

END mark_transactions;

---------------------------------------------------------------------------------
-- Check activity
---------------------------------------------------------------------------------
PROCEDURE check_activity(o_rc IN OUT NUMBER, o_err_msg IN OUT VARCHAR2) IS

  l_line_count  NUMBER := 0;
  l_gap_minutes NUMBER := 0;
  l_gap_threshold NUMBER := 0;
  l_procname VARCHAR2(30) := 'check_activity';

BEGIN

  zlog.write_msg(1, 'Started ' || l_procname);

------------------------------------------------
-- Check to ensure transactions are still flowing
-- from IMS to RMS via the TPE pipe.
-- If it's been over 4 hours since the last
-- transaction then send email to the RMS team.
------------------------------------------------

  select parm_num1
    INTO l_gap_threshold
    from zms_parms
   where process_name = c_program;

  zlog.write_msg(1, 'Threshold Gap minutes =' || l_gap_threshold);

  SELECT /*+ parallel(a,8) */ ROUND(1440 * (sysdate - MAX(insert_date)), 0)
    INTO l_gap_minutes
    FROM zms_ifi_ims_tran_data a;

  zlog.write_msg(1, 'Gap minutes since last record received=' || l_gap_minutes);

  IF (l_gap_minutes > l_gap_threshold)
  THEN
    zlog.write_msg(1, 'WARNING:  No TPE records have been sent in the last ' || l_gap_minutes || ' minutes.');
    zlog.write_msg(1, 'Send email to RMS team');

    SELECT name INTO g_database from v$database;

    g_mesg := 'Contact IMS/ESI team.  It has been ' || l_gap_minutes || ' minutes since last TPE record was received from IMS';
    g_subj := 'WARNING(' || g_database || '):  TPE is not receiving transactions from IMS';

    pid_email_pkg.mail(sender      => 'support <noreply@zalecorp.com>'
                       ,recipients => '"ITMerchandisingDallas"<ITMerchandisingDallas@signetjewelers.com>'
                       ,subject    => g_subj
                       ,message    => g_mesg);

    zlog.write_msg(1, 'Sent email - sqlcode=' || sqlcode);

  END IF;

  o_rc := 0;

EXCEPTION

  WHEN OTHERS THEN

    o_rc := sqlcode;
    o_err_msg := sqlerrm;
    zlog.write_error('Procedure ' || l_procname || ' failed to check activity');
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    ROLLBACK;

END check_activity;

---------------------------------------------------------------------------------
-- Add new item locs
---------------------------------------------------------------------------------
PROCEDURE add_new_item_locs(o_rc IN OUT NUMBER, o_err_msg IN OUT VARCHAR2) IS

  l_line_count NUMBER := 0;
  l_item item_master.item%TYPE;
  l_loc store.store%TYPE;
  l_tot_recs_processed NUMBER := 0;
  l_tot_recs_added NUMBER := 0;
  l_err_code NUMBER;
  l_err_msg VARCHAR2(1000);
  l_new_err_msg VARCHAR2(1000);
  l_step NUMBER := 0;
  l_procname VARCHAR2(30) := 'add_new_item_locs';

CURSOR c1 IS
WITH ims_td AS
(SELECT /*+ parallel(a,8) */ DISTINCT zms_ims_to_rms_loc_fnc(a.location, a.sku) LOC, a.sku SKU
   FROM zms_ifi_ims_tran_data a
  WHERE (((a.insert_date > g_last_process_time) AND (a.insert_date <= g_start_run_time)) OR (a.process_status = 'N'))
  UNION
 SELECT /*+ parallel(b,8) */ DISTINCT zms_ims_to_rms_loc_fnc(b.other_location, b.sku) LOC, b.sku SKU
   FROM zms_ifi_ims_tran_data b
  WHERE (((b.insert_date > g_last_process_time) AND (b.insert_date <= g_start_run_time)) OR (b.process_status = 'N'))
    AND b.other_location != 0
) 
SELECT DISTINCT DECODE(zal.loc_type, 'W', ims_td.loc || '1001', ims_td.loc) LOC, TO_CHAR(ims_td.sku) ITEM
  FROM ims_td,
       item_master m,
       zms_all_location zal
 WHERE ims_td.loc != 0
   AND TO_CHAR(ims_td.sku) = m.item
   AND ims_td.loc = zal.loc
   AND NOT EXISTS (SELECT 'x'
                     FROM item_loc il
                    WHERE il.item = TO_CHAR(ims_td.sku)
                      AND il.loc = DECODE(zal.loc_type, 'W', ims_td.loc || '1001', ims_td.loc))
ORDER by DECODE(zal.loc_type, 'W', ims_td.loc || '1001', ims_td.loc), ims_td.sku;

BEGIN

  zlog.write_msg(1, 'Started ' || l_procname);

  FOR c1rec IN c1
  LOOP

    l_item := c1rec.item;
    l_loc := c1rec.loc;

    zlog.write_msg(0, 'Processing SKU=' || l_item || ' LOC=' || l_loc);

    l_new_err_msg := NULL;
    l_err_code := 0;
    l_err_msg := NULL;

    l_step := 2;
--
-- Trap the failed call to zms_new_item_loc so that we don't exit our loop.
--
    BEGIN

      ZMS_NEW_ITEM_LOC(l_item, l_loc, l_err_code, l_err_msg);

    EXCEPTION

      WHEN OTHERS THEN
        l_new_err_msg := 'Call to ZMS_NEW_ITEM_LOC error: ' || l_err_code;
        zlog.write_error(l_new_err_msg);
        zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
        zlog.write_msg(0, l_new_err_msg);
        zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
        ROLLBACK;

    END;

    IF (l_err_code <> 0)
    THEN
--
-- Rollback any work that zms_new_item_loc completed
--
      zlog.write_msg(0, 'ERROR:  ZMS_NEW_ITEM_LOC failed with interal errcode=' || l_err_code);
      zlog.write_error('ERROR:  ZMS_NEW_ITEM_LOC failed with interal errcode=' || l_err_code);

      l_step := 3;
      ROLLBACK;

      IF (l_new_err_msg IS NULL)
      THEN
        l_new_err_msg := 'ERROR:  Internal call to ZMS_NEW_ITEM_LOC, errcode=' || l_err_code;
        zlog.write_error(l_new_err_msg || ' ERRMSG: ' || l_err_msg);
        zlog.write_msg(0, l_new_err_msg || ' ERRMSG: ' || l_err_msg);
      END IF;

    ELSE
      zlog.write_msg(0, '     Added SKU=' || l_item || ' LOC=' || l_loc);
      l_tot_recs_added := l_tot_recs_added + 1;

      l_step := 5;

      COMMIT;

    END IF;

    l_tot_recs_processed := l_tot_recs_processed + 1;

  END LOOP;

  zlog.write_msg(0, 'Added ' || l_tot_recs_added ||
                 ' item/loc records out of ' || l_tot_recs_processed || ' total processed');

  o_rc := 0;

EXCEPTION

  WHEN OTHERS THEN

    o_rc := sqlcode;
    o_err_msg := sqlerrm;
    zlog.write_error('Procedure ' || l_procname || ' failed to add new item locs');
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    ROLLBACK;

END add_new_item_locs;

---------------------------------------------------------------------------------
-- MAIN PROCESS -----------------------------------------------------------------
---------------------------------------------------------------------------------

BEGIN

--
-- Setup log files.
--

  IF (zlog.initialize(g_err_msg, c_program, 0, g_debug_lvl) = FALSE)
  THEN
    RAISE INIT_LOG_FAIL;
  END IF;

  zlog.write_msg(0, '------------ START ' || c_program || ' -------------');
  zlog.write_log('Started');

  SELECT vdate INTO g_batch_date FROM period;

  SELECT last_process_datetime, sysdate
    INTO g_last_process_time, g_start_run_time
    FROM zms_process_date
   WHERE process = c_program;

--
-- Reset performance analysis flag (parm_num1) back to zero to start the cycle
-- indicating no performance issue.  If one of the subsequent steps
-- in the zms_tpe_stage processing has a performance issue then it will
-- flip the flag back to 1 indicating a performance issue to all 
-- downstream steps and they will skip their run until system performance is better.
-- Note if we flip the performance active flag (parm_vchar1) to N then we turn off
-- any performance checking for any TPE step.  Back to normal processing.
--

  UPDATE zms_parms 
     SET parm_num1 = 0
   WHERE process_name = 'zms_tpe_stage'
     AND parm_vchar1 = 'Y';
 
  SELECT parm_num2 
    INTO g_threshold_minutes
    FROM zms_parms
   WHERE process_name = 'zms_tpe_stage';

  SELECT /*+ parallel(i,8) */ count(*)
    INTO g_rec_count
    FROM zms_ifi_ims_tran_data i
   WHERE ((insert_date > g_last_process_time) AND (insert_date <= g_start_run_time));

  zlog.write_msg(0, 'Last process time - ' || TO_CHAR(g_last_process_time, 'YYYYMMDD:HH24:MI:SS') || ' Start time - ' ||  TO_CHAR(g_start_run_time, 'YYYYMMDD:HH24:MI:SS') || ' Record Count=' || g_rec_count);
  zlog.write_msg(0, 'Retry Flag=' || g_retry_flag || ' Threshold minutes=' || g_threshold_minutes);

  mark_transactions(g_return_code, g_err_msg);
  IF (g_return_code <> 0)
  THEN
    RAISE FAILED_PROC;
  END IF;

  check_activity(g_return_code, g_err_msg);
  IF (g_return_code <> 0)
  THEN
    RAISE FAILED_PROC;
  END IF;

--  add_new_item_locs(g_return_code, g_err_msg);
--  IF (g_return_code <> 0)
--  THEN
--    RAISE FAILED_PROC;
--  END IF;

  UPDATE zms_process_date
     SET last_process_datetime = g_start_run_time
   WHERE process = c_program;

  SELECT sysdate INTO g_end_run_time FROM dual;

  g_total_run_time := ROUND(1440 * (g_end_run_time - g_start_run_time), 0);

  zlog.write_msg(0, 'TOTAL RUN TIME=' || g_total_run_time || ' MINUTES');

  IF (g_total_run_time > g_threshold_minutes)
  THEN

    --
    -- Flip flag to 1 to indicate a performance issue for downstream TPE steps to not run this round.
    --

    UPDATE zms_parms 
       SET parm_num1 = 1
     WHERE process_name = 'zms_tpe_stage'
       AND parm_vchar1 = 'Y';

    zlog.write_msg(0, 'Performance threshold exceeded. Ran ' || g_total_run_time || ' minutes.');

  END IF;
    
  COMMIT;

  zlog.write_msg(0, '------------ FINISHED ' || c_program || ' -------------');
  zlog.write_log('Terminated successfully');

  IF (zlog.close_all_logs(g_err_msg, FALSE) = FALSE)
  THEN
    RAISE CLOSE_LOG_FAIL;
  END IF;

---------------------------------------------------------------------------------
-- EXCEPTION PROCESSING ---------------------------------------------------------
---------------------------------------------------------------------------------

EXCEPTION

  WHEN INIT_LOG_FAIL THEN
    dbms_output.put_line('ERROR:  Failed to init logs, ERRMSG=' || g_err_msg);
    RAISE;

  WHEN CLOSE_LOG_FAIL THEN
    dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
    RAISE;

  WHEN FAILED_PROC THEN
    ROLLBACK;
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    IF (zlog.close_all_logs(g_err_msg, FALSE) = FALSE)
    THEN
     dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
    END IF;
    RAISE;

  WHEN OTHERS THEN
    ROLLBACK;
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    IF (zlog.close_all_logs(g_err_msg, FALSE) = FALSE)
    THEN
     dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
    END IF;
    RAISE;

END;
/

exit
