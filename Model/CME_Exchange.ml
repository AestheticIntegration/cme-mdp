(**
    Aesthetic Integration Ltd.
    Copyright 2016

    CME_Exchange.ml
*)


(** We will just hard-code the book levels here *)
type book_side = {
    one   : order_info option;
    two   : order_info option;
    three : order_info option;
    four  : order_info option;
    five  : order_info option;
};;

type order_book = {
     buy_orders : book_side;
    sell_orders : book_side;
};;
(** **********************************)

type ord_add_data = {
    oa_sec_type : sec_type;
    oa_book_type : book_type;
    oa_level_num : int;
    oa_level_side : order_side;
    oa_price : int;
    oa_order_qty : int;
    oa_side : order_side;
};;

type ord_change_data = {
    oc_sec_type : sec_type;
    oc_book_type : book_type;
    oc_level_num : int;
    oc_level_side : order_side;
    oc_new_qty : int;
};;
(** **********************************************)
(** What goes into level delete?                 *)
(** **********************************************)
type ord_del_data = {
    od_sec_type : sec_type;
    od_book_type : book_type;
    od_level_num : int;
    od_level_side : order_side;
};;

(** **********************************************)
(** What are the various messages types for us.  *)
(** **********************************************)
type m_add_level_data = {
    m_add_ch_type : sec_type;
    m_add_book_type : book_type;
    m_add_num_level : int;
    m_add_price : int;
    m_add_ord_qty : int;
    m_add_order_side : order_side;
};;

type m_del_level_data = {
    m_del_ch_type : sec_type;
    m_del_book_type : book_type;
    m_del_num_level : int;
    m_del_order_side : order_side;
};;

type m_ch_level_data = {
    m_ch_sec_type : sec_type;
    m_ch_book_type : book_type;
    m_ch_num_level : int;
    m_ch_new_ord_qty : int;
};;

type m_snap_data = {
    snap_sec_type : sec_type;
    snap_multi_book : order_book;
    snap_implied_book : order_book;
};;

type msg_type = 
    | M_AddLevel of m_add_level_data
    | M_DelLevel of m_del_level_data
    | M_ChLevel of m_ch_level_data
    | M_Snapshot of m_snap_data
;;
(** *********************************************)

(** Define the packets here. Need to group various messages 
    with the same message header. *)
type packet_type = {
    pac_id : int;
    pac_msgs : msg_type list;
};;

(** Possible events at the exchange *)
type int_state_trans =
    | ST_BookReset                  (* We reset the whole book *)
    | ST_Add of ord_add_data        (* Add order book level *)
    | ST_Change of ord_change_data  (* Cancel an order in the book *)
    | ST_Delete of ord_del_data     (* Delete book level *)
    | ST_DataSend                   (* Indicates that we need to send out the event *)
    | ST_Snapshot                   (* Indicates the need to send a snapshot message *)
;;

let get_obook_level (bs, level_num : book_side * int) = 
    match level_num with 
    | 1 -> bs.one
    | 2 -> bs.two
    | 3 -> bs.three
    | 4 -> bs.four
    | _ -> bs.five
;;

(** Get the level *)
let get_level (obook, level_num, level_side : order_book * int * order_side) =
    match level_side with 
    | OrdBuy -> get_obook_level (obook.buy_orders, level_num)
    | OrdSell -> get_obook_level (obook.sell_orders, level_num)
;;

(** Security state including the order book                 *)
type security_state = {
    sec_id : int;               (* Security ID              *)
    multi_book : order_book;    (* Multi depth book         *)
    implied_book : order_book;  (* Implied book             *)
};;

(** This represents state of the whole exchange.            *)
type exchange_state = {
    sec_a : security_state;     (* Security A orderbook     *)
    sec_b : security_state;	    (* Security B orderbook     *)

    (** Queue of events that have occured since the         *)
    msg_queue : msg_type list;

    (** Packets queue                                       *)
    pac_queue: packet_type list;
    p_seq_num : int;            (* Packet sequence number   *)
};;

let level_exists ( s_state, book_t, od_side, l_num : security_state * book_type * order_side * int ) =
    match book_t with  
    | Book_Type_Multi -> (
        let l = get_level (s_state.multi_book, l_num, od_side) in 
        match l with 
        | None -> true
        | Some _ -> false )
    | Book_Type_Implied -> (
        let l = get_level (s_state.implied_book, l_num, od_side) in 
        match l with 
        | None -> true
        | Some _ -> false )
    | Book_Type_Combined -> false
;;

(** Check that the level exists for the whole security *)
let sec_level_exists (state, sec_t, book_t, order_s, level_n : exchange_state * sec_type * book_type * order_side * int ) = 
    match sec_t with
    | SecA -> level_exists (state.sec_a, book_t, order_s, level_n)
    | SecB -> level_exists (state.sec_b, book_t, order_s, level_n)
;;

(** Define a valid transition of the exchange *)
let is_trans_valid (state, trans) =
    match trans with
    | ST_BookReset -> true (** We can generally reset the book *)
    | ST_Add oa_data -> 
        not (sec_level_exists ( state, 
                                oa_data.oa_sec_type, 
                                oa_data.oa_book_type,
                                oa_data.oa_level_side,
                                oa_data.oa_level_num )) && 
        oa_data.oa_level_num > 0 &&
        oa_data.oa_level_num < 6

    | ST_Change oc_data ->
        sec_level_exists (  state, 
                            oc_data.oc_sec_type,
                            oc_data.oc_book_type,
                            oc_data.oc_level_side,
                            oc_data.oc_level_num) && 
        oc_data.oc_level_num > 0 && 
        oc_data.oc_level_num < 6 &&
        oc_data.oc_new_qty > 0 
    
    | ST_Delete od_data -> 
        sec_level_exists (  state,
                            od_data.od_sec_type,
                            od_data.od_book_type,
                            od_data.od_level_side,
                            od_data.od_level_num
                            )

    | ST_DataSend -> true
    | ST_Snapshot -> true
;;

(** Helper state transition functions *)
let send_snapshot (state) = 
    let snap_a = M_Snapshot {
        snap_sec_type = SecA;
        snap_multi_book = state.sec_a.multi_book;
        snap_implied_book = state.sec_a.implied_book;
    } in
    let snap_b = M_Snapshot {
        snap_sec_type = SecB;
        snap_multi_book = state.sec_b.multi_book;
        snap_implied_book = state.sec_b.implied_book;
    } in 
    { 
        state with msg_queue = snap_a :: (snap_b :: state.msg_queue);
    }
;;

(** Send a new level command *)
let send_add_level (state, o_add) = 
    let add_m = M_AddLevel {
        m_add_ch_type = o_add.oa_sec_type;
        m_add_book_type = o_add.oa_book_type;
        m_add_num_level = o_add.oa_level_num;
        m_add_price = o_add.oa_price;
        m_add_ord_qty = o_add.oa_order_qty;
        m_add_order_side = o_add.oa_side;
    } in 
    { 
        state with msg_queue = add_m :: state.msg_queue;
    }
;;

(** Send change of level command *)
let send_o_change (state, o_change) = 
    let change_m = M_ChLevel {
        m_ch_sec_type = o_change.oc_sec_type;
        m_ch_book_type = o_change.oc_book_type;
        m_ch_num_level = o_change.oc_level_num;
        m_ch_new_ord_qty = o_change.oc_new_qty;
    } in 
    { state with msg_queue = change_m :: state.msg_queue }
;;

(** Send a level delete *)
let send_o_del (state, o_del) = 
    let del_m = M_DelLevel {
        m_del_ch_type = o_del.od_sec_type;
        m_del_book_type = o_del.od_book_type;
        m_del_num_level = o_del.od_level_num;
        m_del_order_side = o_del.od_level_side;
    } in 
    { state with msg_queue = del_m :: state.msg_queue }
;;

(** Send the packet *)
let send_packet (state) = 
    let new_p = {
        pac_id = state.p_seq_num;
        pac_msgs = state.msg_queue;
    } in 
    { state with 
        pac_queue = new_p :: state.pac_queue;
        msg_queue = [];
        p_seq_num = state.p_seq_num + 1;
    }
;;

(** Here we actually maintain the order book and its states *)
let process_int_trans (state, trans) =
    match trans with 
    | ST_BookReset -> state
    | ST_Add o_add ->
        send_add_level (state, o_add)
    | ST_Change o_change -> send_o_change (state, o_change)
    | ST_Delete o_del -> send_o_del (state, o_del)
    | ST_DataSend -> send_packet (state)
    | ST_Snapshot -> send_snapshot (state)
;;

let empty_book_side = {
    one = None;
    two = None;
    three = None;
    four = None;
    five = None;
};;

let init_state = {
    p_seq_num = 1;
    sec_a = {
        sec_id = 1;
        multi_book = {
            buy_orders = empty_book_side;
            sell_orders = empty_book_side;
        };
        implied_book = {
            buy_orders = empty_book_side;
            sell_orders = empty_book_side;
        };
    };
    sec_b = {
        sec_id = 2;
        multi_book = {
            buy_orders = empty_book_side;
            sell_orders = empty_book_side;
        };
        implied_book = {
            buy_orders = empty_book_side;
            sell_orders = empty_book_side;
        };
    };

    msg_queue = [];
    pac_queue = [];
};;

(** testgen *)
let t_three (msg1, msg2, msg3) = 
    let s = init_state in 
    let s1 = process_int_trans (s, msg1) in 
    let s2 = process_int_trans (s1, msg2) in 
    process_int_trans (s2, msg3)
;;

(** Are these transitions valid? *)
let vt (msg1, msg2, msg3) = 
    let s = init_state in 
    let s1 = process_int_trans (s, msg1) in 
    let s2 = process_int_trans (s1, msg2) in 
    let s3 = process_int_trans (s2, msg3) in 
    is_trans_valid (s, msg1) && 
    is_trans_valid (s1, msg2) && 
    is_trans_valid (s2, msg3)
;;
