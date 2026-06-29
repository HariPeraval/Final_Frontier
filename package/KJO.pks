CREATE OR REPLACE PACKAGE ZMS.kjo IS
/*********************************************************************/
/* PACKAGE: kjo                                                      */
/* DESCRIPTION: does all of the processing needed to perform a pick  */
/*********************************************************************/
   PROCEDURE p_kjo_alloc_sku_groups (p_is_forecast IN BOOLEAN,
                                     O_err_code   OUT INTEGER);--
   PROCEDURE p_kjo_scarce_resources_ctl(O_err_code OUT INTEGER);--
   PROCEDURE p_kjo_alloc_scarce_resources (l_ctl_orig_wh    IN NUMBER,
                                           l_ctl_process_no IN NUMBER,
                                           l_ctl_pick_wh    IN NUMBER,
                                           l_ctl_prev_wh    IN NUMBER,
                                           O_err_code      OUT INTEGER);--
   PROCEDURE p_kjo_upd_feedback_reqdetail(O_err_code OUT INTEGER);--  
END kjo;
/
GRANT EXECUTE ON ZMS.KJO TO RMS_USER;
GRANT DEBUG ON ZMS.KJO TO ZMSBATCH;
GRANT EXECUTE ON ZMS.KJO TO ZMSBATCH;
create or replace public synonym KJO for zms.KJO;
