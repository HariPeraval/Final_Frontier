-- *************************************************************
-- This program processes the Kjo Main Sku and Sub sku into zms_mainsub
--
--
SET SERVEROUTPUT ON SIZE 1000000
SET TIMING ON

SPOOL ${LOGDIR}/zms_kjo_main_sub_item_Load.sqllog 

VARIABLE ret_code NUMBER;
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT SQL.SQLCODE

 DECLARE

    INIT_LOG_FAIL       EXCEPTION;
    CLOSE_LOG_FAIL      EXCEPTION; 
    CALL_PROC_FAIL      EXCEPTION; 
    g_err_msg           VARCHAR2(500);
    g_debug_lvl         INTEGER := 1;
    c_program           CONSTANT VARCHAR2(30) := 'zms_kjo_main_sub_item_Load';
    lo_err_code         number := 0;  -- 0 success - 1 error 
    v_job_name          VARCHAR2(50) := 'zms_kjo_main_sub_item_Load';
    v_job_start_time    DATE := SYSDATE;
    v_job_end_time      DATE;
    v_process_date      DATE := SYSDATE; 
    v_next_recalc_date  DATE; 
    v_table_name        VARCHAR2(50);
    v_sql_number        NUMBER :=0;
    v_sql_start_time    DATE;
    v_sql_end_time      DATE;
    v_process_ind       VARCHAR2(3);
    v_process_qty       NUMBER;
    v_sql               VARCHAR2(100); 
    v_vdate             DATE; 
    v_total             NUMBER :=0; 

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
    :ret_code := 0;

	 insert into zms_mainsub
	 ( mainsku,sku,div    )
	 select distinct main_sku item,sku sub_item,initiated_brand  
	   from pid_sku_master a,
			repl_item_loc b
	  where initiated_brand in (20,80,90,170)
		and a.main_sku <> a.sku  
		and a.main_sku=b.item 
		and not exists (select 1 from zms_mainsub t
						  where t.mainsku=a.main_sku
							and t.sku=a.sku
							and t.div=a.initiated_brand);

      zlog.write_msg(g_debug_lvl,'KJO Sub main sku and sku Records to Process - : ' || v_total);
 
      COMMIT;  

      zlog.write_msg(g_debug_lvl,'*** Process Completed '||to_char(sysdate,'mm/dd/yyyy hh24:mi:ss'));
      zlog.write_log('Successfully Completed'); 

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

WHEN OTHERS
        THEN
        :ret_code := SQLCODE();
        zlog.write_error('ERROR:  Failed for some other unknown reason ' || substr(sqlerrm,1,200));
        RAISE;

END;
/
SPOOL OFF;
EXIT :ret_code
