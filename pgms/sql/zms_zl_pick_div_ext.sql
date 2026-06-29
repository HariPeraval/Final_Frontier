-- *************************************************************
-- This program inserts into the zms_zpf_pick_div_ext table and does
-- pre-processing for the pick
-- 05/25/2026 - Hari -   KJO pick generation changes
-- 
SET SERVEROUTPUT ON SIZE 1000000
SET TIMING ON

SPOOL ${LOGDIR}/zms_zl_pick_div_ext.sqllog
--SPOOL zms_zl_pick_div_ext.sqllog

WHENEVER SQLERROR EXIT FAILURE;
WHENEVER OSERROR  EXIT FAILURE;

 DECLARE
    INIT_LOG_FAIL       EXCEPTION;
    CLOSE_LOG_FAIL      EXCEPTION;
    CALL_PROC_FAIL      EXCEPTION;

    g_err_msg           VARCHAR2(500);
    g_debug_lvl         INTEGER := 1;
    c_program           CONSTANT VARCHAR2(30) := 'zms_zl_pick_div_ext';
    lo_err_code         NUMBER := 0;  -- 0 success

    v_job_name          VARCHAR2(50) := 'zms_zl_pick_div_ext';
    v_job_start_time    DATE := SYSDATE;
    v_job_end_time      DATE;
    v_process_date      DATE := SYSDATE;
    v_update_source     VARCHAR2(30) := 'zms_zpf_div_extract';
    v_next_recalc_date  DATE;
    
    v_table_name        VARCHAR2(50);
    v_proc_name         VARCHAR2(50);
    v_sql_number        NUMBER :=0;
    v_sql_start_time    DATE;
    v_sql_end_time      DATE;
    v_process_ind       VARCHAR2(3);
    v_process_qty       NUMBER;
    v_sql               VARCHAR2(100);
    v_freq_run          VARCHAR2(10);

    v_vdate             DATE;
    v_run_date          DATE;
    v_maximum_pick      NUMBER;
    v_exceeded          NUMBER;
    v_total             NUMBER;

----------------------------------------------------------------------------------------
---  MAIN PROCESS
----------------------------------------------------------------------------------------

BEGIN

    IF (zlog.initialize(g_err_msg, c_program, 0, g_debug_lvl) = FALSE)
            THEN RAISE INIT_LOG_FAIL;
    END IF;

    zlog.write_log('Started');


----------------------------------------------------------------------------------------

    SELECT vdate INTO v_vdate FROM period;

    DBMS_OUTPUT.PUT_LINE('Current process date,   v_vdate             is : ' ||
                                        to_char(v_process_date,'DD-MON-YYYY'));

    DBMS_OUTPUT.PUT_LINE('System_date,            v_process_date      is : ' ||
                                        to_char(v_process_date,'DD-MON-YYYY HH24:MI'));

    dbms_output.put_line('.');

----------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Truncate zms_zpf_div_extract');

      zms_truncate_tab('zms_zpf_div_extract');

----------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Call ZPF.P_ZPF_DIV_EXTRACT_EXT');
    v_proc_name := 'ZPF.P_ZPF_DIV_EXTRACT_EXT';

      ZPF.P_ZPF_DIV_EXTRACT_EXT(FALSE,lo_err_code);

      IF (lo_err_code != 0)
      THEN
        zlog.write_msg(g_debug_lvl,'Problem exec proc ZPF.P_ZPF_DIV_EXTRACT_EXT - return code ' || lo_err_code);
        RAISE CALL_PROC_FAIL;
      END IF;

    zlog.write_msg(g_debug_lvl,'*** Process Completed '||to_char(sysdate,'mm/dd/yyyy hh24:mi:ss'));
    zlog.write_log('Successfully Completed');

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Call ZPF.P_ZPF_PROCESS_OVERRIDES');
    v_proc_name := 'ZPF.P_ZPF_PROCESS_OVERRIDES';

      ZPF.P_ZPF_PROCESS_OVERRIDES(FALSE,lo_err_code);

      IF (lo_err_code != 0)
      THEN
        zlog.write_msg(g_debug_lvl,'Problem exec proc ZPF.P_ZPF_PROCESS_OVERRIDES - return code ' || lo_err_code);
        RAISE CALL_PROC_FAIL;
      END IF;

      COMMIT;

    zlog.write_msg(g_debug_lvl,'*** Process Completed '||to_char(sysdate,'mm/dd/yyyy hh24:mi:ss'));
    zlog.write_log('Successfully Completed');

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Analyzing ZMS_ZPF_DIV_EXTRACT');

      DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_ZPF_DIV_EXTRACT');

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Insert Pagoda records into zms_ppf_div_extract - Start');

      INSERT INTO zms_ppf_div_extract
          (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, alloc_id,
           orig_wh, orig_ord_qty, orig_req, orig_po_type, cust_name, pick_process_nbr)
       SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
              in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
              request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, alloc_id,
              orig_wh, orig_ord_qty, orig_req, orig_po_type, cust_name, pick_process_nbr
         FROM zms_zpf_div_extract zpf
        WHERE zpf.division = 150;

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

      COMMIT;

      zlog.write_msg(g_debug_lvl,'Insert Pagoda records into zms_ppf_div_extract - End - Total rows inserted : '|| v_process_qty);

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Delete Pagoda records from zms_zpf_div_extract - Start');

      DELETE FROM zms_zpf_div_extract
       WHERE division = 150;

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

      COMMIT;

    zlog.write_msg(g_debug_lvl,'Delete Pagoda records from zms_zpf_div_extract - End - Total rows deleteed : '|| v_process_qty);
    
    ---------------------------Start Kjo pick Changes------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Insert kjo records into zms_kjo_div_extract - Start');

      INSERT INTO zms_kjo_div_extract
          (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, alloc_id,
           orig_wh, orig_ord_qty, orig_req, orig_po_type, cust_name, pick_process_nbr)
       SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
              in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
              request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, alloc_id,
              orig_wh, orig_ord_qty, orig_req, orig_po_type, cust_name, pick_process_nbr
         FROM zms_zpf_div_extract zpf
        WHERE zpf.division in (20,80,90,170);

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

      COMMIT;

      zlog.write_msg(g_debug_lvl,'Insert Pagoda records into zms_kjo_div_extract - End - Total rows inserted : '|| v_process_qty);

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Delete kjo records from zms_zpf_div_extract - Start');

      DELETE FROM zms_zpf_div_extract
       WHERE division in (20,80,90,170);

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

      COMMIT;

    zlog.write_msg(g_debug_lvl,'Delete kjo records from zms_zpf_div_extract - End - Total rows deleteed : '|| v_process_qty);

    ----------------------------------End Kjo pick Changes-------------------------------------------
      
    zlog.write_msg(g_debug_lvl,'Analyzing ZMS_ZPF_DIV_EXTRACT');

      DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_ZPF_DIV_EXTRACT');

    -----------------------------------------------------------------------------------------------
      
    zlog.write_msg(g_debug_lvl,'Analyzing ZMS_PPF_DIV_EXTRACT');

      DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_PPF_DIV_EXTRACT');
	  
    --------------------------Start Kjo pick Changes-----------------------------------------------
      
    zlog.write_msg(g_debug_lvl,'Analyzing ZMS_KJO_DIV_EXTRACT');

      DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_KJO_DIV_EXTRACT');
	  
    ----------------------------------End Kjo pick Changes-------------------------------------------
      
    zlog.write_msg(g_debug_lvl,'Count number of rows in zms_zpf_div_extract');

        SELECT count(*) INTO v_total FROM zms_zpf_div_extract;

    zlog.write_msg(g_debug_lvl,'Number of rows zms_zpf_div_extract :'  || to_char(v_total));

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Count number of rows in zms_ppf_div_extract');

        SELECT count(*) INTO v_total FROM zms_ppf_div_extract;

    zlog.write_msg(g_debug_lvl,'Number of rows zms_ppf_div_extract :'  || to_char(v_total));
	
    --------------------------Start Kjo pick Changes------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Count number of rows in ZMS_KJO_DIV_EXTRACT');

        SELECT count(*) INTO v_total FROM ZMS_KJO_DIV_EXTRACT;

    zlog.write_msg(g_debug_lvl,'Number of rows ZMS_KJO_DIV_EXTRACT :'  || to_char(v_total));

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Insert into zms_zpf_div_extract_bk - Pick2');

    INSERT INTO zms_zpf_div_extract_bk
       (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
        in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
        request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
        process_type, process_date, orig_wh, orig_ord_qty, 
        orig_req, orig_po_type, pick_process_nbr)
    SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
           'Pick2' process_type, sysdate process_date, orig_wh, orig_ord_qty, 
           orig_req, orig_po_type, pick_process_nbr
      FROM zms_zpf_div_extract;

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

    COMMIT;

    zlog.write_msg(g_debug_lvl,'Insert into zms_zpf_div_extract_bk - End - Total rows inserted : '|| v_process_qty);

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Insert into zms_ppf_div_extract_bk - Pick2');

    INSERT INTO zms_ppf_div_extract_bk
       (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
        in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
        request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
        process_type, process_date, orig_wh, orig_ord_qty,
        orig_req, orig_po_type, pick_process_nbr)
    SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
           'Pick2' process_type, sysdate process_date, orig_wh, orig_ord_qty,
           orig_req, orig_po_type, pick_process_nbr
      FROM zms_ppf_div_extract;

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

    COMMIT;

    zlog.write_msg(g_debug_lvl,'Insert into zms_ppf_div_extract_bk - End - Total rows inserted : '|| v_process_qty);

    --------------------------Start Kjo pick Changes------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Insert into zms_kjo_div_extract_bk - Pick2');

    INSERT INTO zms_kjo_div_extract_bk
       (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
        in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
        request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
        process_type, process_date, orig_wh, orig_ord_qty,
        orig_req, orig_po_type, pick_process_nbr)
    SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
           'Pick2' process_type, sysdate process_date, orig_wh, orig_ord_qty,
           orig_req, orig_po_type, pick_process_nbr
      FROM zms_kjo_div_extract;

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

    COMMIT;

    zlog.write_msg(g_debug_lvl,'Insert into zms_kjo_div_extract_bk - End - Total rows inserted : '|| v_process_qty);
	
    ----------------------------------End Kjo pick Changes-------------------------------------------
	
-- Successful End

zlog.write_log('Successfully Completed');

-- Write Counters

zlog.write_msg(1, 'No of Records in zms_zpf_div_extract: '||v_total);

-- Close logs

IF (zlog.close_all_logs(g_err_msg, FALSE) = FALSE)
        THEN RAISE CLOSE_LOG_FAIL;
END IF;

-- Exception Handling

EXCEPTION

WHEN INIT_LOG_FAIL
        THEN
        dbms_output.put_line('ERROR:  Failed to init logs, ERRMSG=' || g_err_msg);
        RAISE;

WHEN CLOSE_LOG_FAIL
        THEN
        dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
        RAISE;

WHEN CALL_PROC_FAIL THEN
        ROLLBACK;
        zlog.write_log('Aborted');
        zlog.write_msg(g_debug_lvl, 'ERROR: ' || v_proc_name || ' returned error code ' || lo_err_code);
        zlog.write_error('ERROR: ' || v_proc_name || ' returned error code ' || lo_err_code);
        IF NOT zlog.close_all_logs(g_err_msg, TRUE)
        THEN
          dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
        END IF;
        RAISE;

WHEN OTHERS
        THEN
        zlog.write_error('ERROR:  Failed for some other unknown reason ' || substr(sqlerrm,1,200));
        RAISE;

END;

/
SPOOL OFF;
EXIT
