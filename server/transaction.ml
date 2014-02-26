(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

let debug fmt = Logging.debug "transaction" fmt
open Xenstore

let none = 0l
let test_eagain = ref false

type ty = No | Full of (int32 * Node.t * Store.t)

type side_effects = {
        (* A log of all the store updates in this transaction. When the transaction
           is committed, these paths need to be committed to stable storage. *) 
        mutable writes: Protocol.Path.t list;
        mutable deletes: Protocol.Path.t list;
        (* A log of updates which should generate a watch events. Note this can't
           be derived directly from [writes] above because implicit directory
           creates don't generate watches (for no good reason) *)
	mutable watches: (Protocol.Op.t * Protocol.Name.t) list;
}

let no_side_effects () = { writes = []; deletes = []; watches = [] }

let get_watches side_effects = side_effects.watches
let get_writes side_effects = side_effects.writes
let get_deletes side_effects = side_effects.deletes

type t = {
	ty: ty;
	store: Store.t;
	quota: Quota.t;
        (* Side-effects which should be generated when the transaction is committed. *)
        side_effects: side_effects;
        (* A log of all the requests and responses during this transaction. When
           committing a transaction to a modified store, we replay the requests and
           abort the transaction if any of the responses would now be different. *)
	mutable operations: (Protocol.Request.payload * Protocol.Response.payload) list;
}

let make id store =
	let ty = if id = none then No else Full(id, store.Store.root, store) in
	{
		ty = ty;
		store = if id = none then store else Store.copy store;
		quota = Quota.copy  store.Store.quota;
                side_effects = no_side_effects ();
		operations = [];
	}

let get_id t = match t.ty with No -> none | Full (id, _, _) -> id
let get_store t = t.store
let get_side_effects t = t.side_effects

let add_watch t ty path = t.side_effects.watches <- (ty, Protocol.Name.Absolute path) :: t.side_effects.watches
let add_operation t request response = t.operations <- (request, response) :: t.operations
let get_operations t = List.rev t.operations

let mkdir t creator perm path =
        if not (Store.exists t.store path) then (
                Protocol.Path.iter (fun prefix ->
                        if not(Store.exists t.store prefix) then begin
                                Store.mkdir t.store creator perm prefix;
                                t.side_effects.writes <- path :: t.side_effects.writes;
                                (* no watches for implicitly created directories *)
                        end
                ) path;
                add_watch t Protocol.Op.Mkdir path
        )

let write t creator perm path value =
        mkdir t creator perm (Protocol.Path.dirname path);
	Store.write t.store creator perm path value;
        t.side_effects.writes <- path :: t.side_effects.writes;
        add_watch t Protocol.Op.Write path

let setperms t perm path perms =
	Store.setperms t.store perm path perms;
        t.side_effects.writes <- path :: t.side_effects.writes;
	add_watch t Protocol.Op.Setperms path

let rm t perm path =
	Store.rm t.store perm path;
        t.side_effects.writes <- path :: t.side_effects.writes;
	add_watch t Protocol.Op.Rm path

let exists t perms path = Store.exists t.store path
let ls t perm path = Store.ls t.store perm path
let read t perm path = Store.read t.store perm path
let getperms t perm path = Store.getperms t.store perm path

let commit ~con t =
	let has_commited =
	match t.ty with
	| No                         -> true
	| Full (id, oldroot, cstore) ->
                let try_commit oldroot cstore store =
			if oldroot == cstore.Store.root then (
				(* move the new root to the current store, if the oldroot
				   has not been modified *)
                                if t.side_effects.writes <> [] || t.side_effects.deletes <> [] then (
					Store.set_root cstore store.Store.root;
					Store.set_quota cstore store.Store.quota
				);
				true
			) else
                                false
                        in
		if !test_eagain && Random.int 3 = 0 then
			false
		else
			try_commit oldroot cstore t.store
	in
	if not has_commited 
	then Logging.conflict ~tid:(get_id t) ~con
	else Logging.commit ~tid:(get_id t) ~con;
	has_commited
