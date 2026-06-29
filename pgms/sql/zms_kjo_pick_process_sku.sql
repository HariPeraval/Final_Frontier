-- *************************************************************
-- This program processes the zms_kjo_pick_process_sku
--
--
SET SERVEROUTPUT ON SIZE 1000000
SET TIMING ON

SPOOL ${LOGDIR}/zms_kjo_pick_process_sku.sqllog
--SPOOL zms_kjo_pick_process_sku.sqllog

VARIABLE ret_code NUMBER;
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT SQL.SQLCODE

 DECLARE

    INIT_LOG_FAIL       EXCEPTION;
    CLOSE_LOG_FAIL      EXCEPTION;
    NO_PICK_TODAY       EXCEPTION;
    CALL_PROC_FAIL      EXCEPTION;

    g_err_msg           VARCHAR2(500);
    g_debug_lvl         INTEGER := 1;
    c_program           CONSTANT VARCHAR2(30) := 'zms_kjo_pick_process_sku';
    lo_err_code         number := 0;  -- 0 success - 1 error

    v_job_name          VARCHAR2(50) := 'zms_kjo_pick_process_sku';
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

      :ret_code := 0;

      SELECT count(1) INTO v_total FROM zms_kjo_div_extract;

      IF (v_total = 0)
      THEN
        zlog.write_msg(g_debug_lvl,'No kjo Pick Records to Process - Records: ' || v_total);
        RAISE NO_PICK_TODAY;
      END IF;

      zlog.write_msg(g_debug_lvl,'KJO Pick Records to Process - Initial Record Extract: ' || v_total);

    ------------------------------------------------------------

      zlog.write_msg(g_debug_lvl,'Call KJO.P_KJO_ALLOC_SCARCE_RESOURCES');

      KJO.P_KJO_SCARCE_RESOURCES_CTL(lo_err_code);

      IF (lo_err_code != 0)
      THEN
        zlog.write_msg(g_debug_lvl,'Problem exec proc KJO.P_KJO_SCARCE_RESOURCES_CTL - return code ' || lo_err_code);
        RAISE CALL_PROC_FAIL;
      END IF;

      zlog.write_msg(g_debug_lvl,'*** Process Completed '||to_char(sysdate,'mm/dd/yyyy hh24:mi:ss'));
      zlog.write_log('Successfully Completed');

    -----------------------------------------------------------------------------------------------

      zlog.write_msg(g_debug_lvl,'Analyzing ZMS_KJO_DIV_EXTRACT');
      DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_KJO_DIV_EXTRACT');

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
        :ret_code := 1;
        dbms_output.put_line('ERROR:  Failed to init logs, ERRMSG=' || g_err_msg);
        RAISE;

WHEN CLOSE_LOG_FAIL
        THEN
        :ret_code := 1;
        dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
        RAISE;

WHEN NO_PICK_TODAY
        THEN
        :ret_code := 95;
        zlog.write_log('Processing bypassed: No Pagoda Pick Records to Process');

WHEN CALL_PROC_FAIL 
        THEN
        :ret_code := SQLCODE();
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
        :ret_code := SQLCODE();
        zlog.write_error('ERROR:  Failed for some other unknown reason ' || substr(sqlerrm,1,200));
        RAISE;

END;
/
SPOOL OFF;
EXIT :ret_code
