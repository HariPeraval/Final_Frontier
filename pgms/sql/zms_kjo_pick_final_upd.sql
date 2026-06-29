-- *************************************************************
-- This program processes the zms_kjo_pick_final_upd
--
--
SET SERVEROUTPUT ON SIZE 1000000
SET TIMING ON

SPOOL ${LOGDIR}/zms_kjo_pick_final_upd.sqllog
--SPOOL zms_kjo_pick_final_upd.sqllog

WHENEVER SQLERROR EXIT FAILURE;
WHENEVER OSERROR  EXIT FAILURE;

 DECLARE

    INIT_LOG_FAIL                  EXCEPTION;
    CLOSE_LOG_FAIL                 EXCEPTION;
    CALL_PROC_FAIL                 EXCEPTION;
    ACTUAL_PICK_PERCENTAGE_TOO_LOW EXCEPTION;

    g_err_msg           VARCHAR2(500);
    g_debug_lvl         INTEGER := 1;
    c_program           CONSTANT VARCHAR2(30) := 'zms_kjo_pick_final_upd';
    lo_err_code         number := 0;  -- 0 success - 1 error

    v_job_name          VARCHAR2(50) := 'zms_kjo_pick_final_upd';
    v_job_start_time    DATE := SYSDATE;
    v_job_end_time      DATE;
    v_process_date      DATE := SYSDATE;
    v_update_source     VARCHAR2(30) := 'ZMS_KJO_PROCESS_EXTRACT';
    v_next_recalc_date  DATE;

    v_proc_name         VARCHAR2(50);
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
    -- Pick Final Update
    ------------------------------------------------------------

      zlog.write_msg(g_debug_lvl,'Call KJO.P_KJO_UPD_FEEDBACK_REQDETAIL');

      KJO.P_KJO_UPD_FEEDBACK_REQDETAIL(lo_err_code);

      IF (lo_err_code != 0)
      THEN
        zlog.write_msg(g_debug_lvl,'Problem exec proc KJO.P_KJO_UPD_FEEDBACK_REQDETAIL - return code ' || lo_err_code);
        RAISE CALL_PROC_FAIL;
      END IF;

      zlog.write_msg(g_debug_lvl,'*** Process Completed '||to_char(sysdate,'mm/dd/yyyy hh24:mi:ss'));
      zlog.write_log('Successfully Completed');

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Delete records from can_dept_override  - Start');

        DELETE FROM can_dept_override;
        v_process_qty := SQL%ROWCOUNT;

        COMMIT;

    zlog.write_msg(g_debug_lvl,'Delete records from can_dept_override  - End - Total rows deleteed : '|| v_process_qty);

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Delete records from can_sku_override   - Start');

        DELETE FROM can_sku_override;
        v_process_qty := SQL%ROWCOUNT;

        COMMIT;

    zlog.write_msg(g_debug_lvl,'Delete records from can_sku_override   - End - Total rows deleteed : '|| v_process_qty);

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Delete records from can_store_override - Start');

        DELETE FROM can_store_override WHERE indicator = 'Y';
        v_process_qty := SQL%ROWCOUNT;

        COMMIT;

    zlog.write_msg(g_debug_lvl,'Delete records from can_store_override - End - Total rows deleteed : '|| v_process_qty); 
	
    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Count number of rows in zms_kjo_div_extract');

        SELECT count(*) INTO v_total FROM zms_kjo_div_extract;

    zlog.write_msg(g_debug_lvl,'Number of rows zms_kjo_div_extract :'  || to_char(v_total));

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Analyzing ZMS_KJO_DIV_EXTRACT');

    DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_KJO_DIV_EXTRACT');

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Insert into zms_kjo_div_extract_bk - Pick3');

    INSERT INTO zms_kjo_div_extract_bk
       (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
        in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
        request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
        process_type, process_date, orig_wh, orig_ord_qty,
        orig_req, orig_po_type, pick_process_nbr)
    SELECT DISTINCT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
           'Pick3' process_type, sysdate process_date, orig_wh, orig_ord_qty,
           orig_req, orig_po_type, pick_process_nbr
      FROM zms_kjo_div_extract;

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

    COMMIT;

    zlog.write_msg(g_debug_lvl,'Insert into zms_kjo_div_extract_bk - End - Total rows inserted : '|| v_process_qty);

    -----------------------------------------------------------------------------------------------

    zlog.write_msg(g_debug_lvl,'Insert into zms_ifi_tsf_ship_pre_req');

    INSERT INTO zms_ifi_tsf_ship_pre_req
       (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
        in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
        request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, alloc_id,
        ship_process_date, ship_process_status, ship_process_qty, ship_extern_doc_nbr,
        rcpt_process_date, rcpt_process_status, rcpt_process_qty)
    SELECT DISTINCT store, sku, req, po_line_nbr, po_type, division,
           sum(ord_qty) over (partition by req, wh, store, request_sku, distro_date) ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, alloc_id,
           NULL, 'N', 0, SUBSTR(req,-7),
           NULL, 'N', 0
      FROM zms_kjo_div_extract;

    v_process_qty := SQL%ROWCOUNT;
    v_sql_end_time := SYSDATE;

    COMMIT;

    zlog.write_msg(g_debug_lvl,'Insert into zms_ifi_tsf_ship_pre_req - End - Total rows inserted : '|| v_process_qty);

    -----------------------------------------------------------------------------------------------

-- Successful End

zlog.write_log('Successfully Completed');

-- Write Counters

zlog.write_msg(1, 'No of Records           Inserted : '|| v_process_qty);

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

WHEN ACTUAL_PICK_PERCENTAGE_TOO_LOW
        THEN
        zlog.write_error('ERROR:  Actual Pick Percentage Too Low ' || v_actual_pick_percent ||'%');
        zlog.write_error('ERROR:     Under 70 Percent            ');
        zlog.write_error('ERROR:  Forecast Pick Qty              ' || v_forecast_pick_qty);
        zlog.write_error('ERROR:  Actual   Pick Qty              ' || v_actual_pick_qty);
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
