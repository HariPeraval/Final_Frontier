-- *************************************************************
-- This program processes the zms_kjo_pick_process_sku_grp
--
--
SET SERVEROUTPUT ON SIZE 1000000
SET TIMING ON

SPOOL ${LOGDIR}/zms_kjo_pick_process_sku_grp.sqllog
--SPOOL zms_kjo_pick_process_sku_grp.sqllog

WHENEVER SQLERROR EXIT FAILURE;
WHENEVER OSERROR  EXIT FAILURE;

 DECLARE

    INIT_LOG_FAIL                  EXCEPTION;
    CLOSE_LOG_FAIL                 EXCEPTION;
    CALL_PROC_FAIL		   EXCEPTION;

    g_err_msg           VARCHAR2(500);
    g_debug_lvl         INTEGER := 1;
    c_program           CONSTANT VARCHAR2(30) := 'zms_kjo_pick_process_sku_grp';
    lo_err_code         number := 0;  -- 0 success - 1 error

    v_job_name          VARCHAR2(50) := 'zms_kjo_pick_process_sku_grp';
    v_job_start_time    DATE := SYSDATE;
    v_job_end_time      DATE;
    v_process_date      DATE := SYSDATE;
    v_update_source     VARCHAR2(30) := 'ZMS_KJO_PROCESS_EXTRACT';
    v_next_recalc_date  DATE;

    v_table_name        VARCHAR2(50);
    v_sql_number        NUMBER :=0;
    v_sql_start_time    DATE;
    v_sql_end_time      DATE;
    v_process_ind       VARCHAR2(3);
    v_process_qty       NUMBER;
    v_sql               VARCHAR2(100);

    v_vdate             DATE;
    v_maximum_pick      NUMBER :=0;
    v_total             NUMBER :=0;

    v_forecast_pick_qty    NUMBER :=0;
    v_actual_pick_qty      NUMBER :=0;
    v_actual_pick_percent  NUMBER :=0;


BEGIN

    IF (zlog.initialize(g_err_msg, c_program, 0, g_debug_lvl) = FALSE)
            THEN RAISE INIT_LOG_FAIL;
    END IF;

    zlog.write_log('Started');

    ------------------------------------------------------------

    SELECT vdate INTO v_vdate FROM period;

    DBMS_OUTPUT.PUT_LINE('Current process date,   v_vdate             is : ' ||
                                        to_char(v_process_date,'DD-MON-YYYY'));

    DBMS_OUTPUT.PUT_LINE('System_date,            v_process_date      is : ' ||
                                        to_char(v_process_date,'DD-MON-YYYY HH24:MI'));

    DBMS_OUTPUT.PUT_LINE('.');

    ------------------------------------------------------------
    -- Process Pick
    ------------------------------------------------------------

      zlog.write_msg(g_debug_lvl,'Call KJO.P_KJO_ALLOC_SKU_GROUPS');

      KJO.P_KJO_ALLOC_SKU_GROUPS(FALSE,lo_err_code);

      IF (lo_err_code != 0)
      THEN
        zlog.write_msg(g_debug_lvl,'Problem exec proc KJO.P_KJO_ALLOC_SKU_GROUPS - return code ' || lo_err_code);
        RAISE CALL_PROC_FAIL;
      END IF;

      zlog.write_msg(g_debug_lvl,'*** Process Completed '||to_char(sysdate,'mm/dd/yyyy hh24:mi:ss'));
      zlog.write_log('Successfully Completed'); 

    -----------------------------------------------------------------------------------------------

      zlog.write_msg(g_debug_lvl,'Analyzing ZMS_KJO_DIV_EXTRACT');
      DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_KJO_DIV_EXTRACT');

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Insert into zms_kjo_div_extract_bk - Pick4');

    INSERT INTO zms_kjo_div_extract_bk
       (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
        in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
        request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
        process_type, process_date, orig_wh, orig_ord_qty, 
        orig_req, orig_po_type, pick_process_nbr)
    SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
           'Pick4' process_type, sysdate process_date, orig_wh, orig_ord_qty, 
           orig_req, orig_po_type, pick_process_nbr
      FROM zms_kjo_div_extract;

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

    COMMIT;

    zlog.write_msg(g_debug_lvl,'Insert into zms_kjo_div_extract_bk - End - Total rows inserted : '|| v_process_qty);

    -----------------------------------------------------------------------------------------------

-- Successful End

zlog.write_log('Successfully Completed');

-- Write Counters

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
        zlog.write_msg(g_debug_lvl, 'ERROR:  KJO.P_KJO_SCARCE_RESOURCES_CTL returned error code ' || lo_err_code);
        zlog.write_error('ERROR:  KJO.P_KJO_SCARCE_RESOURCES_CTL returned error code ' || lo_err_code);
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
