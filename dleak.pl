:- module(dleak,
	  [ dleak/1			% +File
	  ]).

:- use_module(library(pairs)).
:- use_module(library(apply)).
:- use_module(library(lists)).

dleak(File) :-
	cleanup,
	setup_call_cleanup(
	    open(File, read, In),
	    process(In),
	    close(In)),
	report.

process(In) :-
	read(In, Term),
	process(Term, In, dleak{ events:0,
				 contexts:0,
				 malloc:0,
				 calloc:0,
				 realloc:0,
				 free:0,
				 total:0
			       }).

process(end_of_file, _, _) :- !.
process(Term, In, State) :-
	action(Term, State),
	inc(events, State, 1),
	(   State.events mod 10000 =:= 0
	->  format(user_error, '~p~n', [State])
	;   true
	),
	read(In, Term2),
	process(Term2, In, State).

:- dynamic
	cc/2,				% calling context
	chunk/3,
	location/3.			% Location caching

cleanup :-
	retractall(cc(_,_)),
	retractall(chunk(_,_,_)),
	retractall(location(_,_,_)).

inc(Field, State, Extra) :-
	New is State.Field+Extra,
	nb_set_dict(Field, State, New).

action(cc(Id, Stack), State) :-
	inc(contexts, State, 1),
	assertz(cc(Id, Stack)).
action(malloc(Ctx,Size,Ptr), State) :-
	inc(malloc, State, 1),
	inc(total, State, Size),
	assertz(chunk(Ptr,Size,Ctx)).
action(calloc(Ctx,N,Len,Ptr), State) :-
	Size is N*Len,
	inc(calloc, State, 1),
	inc(total, State, Size),
	assertz(chunk(Ptr,Size,Ctx)).
action(realloc(Ctx,Ptr,Size,NPtr), State) :-
	inc(realloc, State, 1),
	(   Ptr == nil
	->  inc(total, State, Size),
	    assertz(chunk(NPtr,Size,Ctx))
	;   retract(chunk(Ptr,OSize,_))
	->  Added is Size-OSize,
	    inc(total, State, Added),
	    assertz(chunk(NPtr,Size,Ctx))
	;   print_message(error, realloc(Ctx,Ptr,Size,NPtr)),
	    abort
	).
action(free(Ctx,Ptr), State) :-
	inc(free, State, 1),
	(   Ptr == nil
	->  true
	;   retract(chunk(Ptr,OSize,_))
	->  inc(total, State, -OSize)
	;   print_message(error, free(Ctx,Ptr))
	).

%%	report
%
%	Report not freed memory with its call stack

report :-
	findall(Ctx-mem(Ptr,Size), chunk(Ptr,Size,Ctx), NotFree),
	keysort(NotFree, Sorted),
	group_pairs_by_key(Sorted, Grouped),
	maplist(sum_not_freed, Grouped, Summed),
	sort(Summed, ByLeak),
	maplist(not_freed, ByLeak).

sum_not_freed(Ctx-Mems, not_freed(Bytes,Count,Ctx)) :-
	length(Mems, Count),
	maplist(arg(2), Mems, Sizes),
	sum_list(Sizes, Bytes).

not_freed(not_freed(Bytes,Count,Ctx)) :-
	print_message(warning, not_freed(Ctx, Count, Bytes)).


:- multifile prolog:message//1.

prolog:message(not_freed(Ctx, Count, Bytes)) -->
	{ cc(Ctx, Stack) },
	[ '~d bytes not freed in ~D allocations at (ctx=~d)'-
	  [Bytes,Count, Ctx], nl],
	context(Stack).
prolog:message(realloc(Ctx,Ptr,_Size,_NPtr)) -->
	{ cc(Ctx, Stack) },
	[ 'realloc() of unknown pointer 0x~16r'-[Ptr], nl ],
	context(Stack).
prolog:message(free(Ctx,Ptr)) -->
	{ cc(Ctx, Stack) },
	[ 'free() of unknown pointer 0x~16r'-[Ptr], nl ],
	context(Stack).

context(Stack) -->
	{ maplist(addr2line, Stack, Human)
	},
	stack(Human).

stack([]) --> [].
stack([H|T]) -->
	[ '    ~w'-[H], nl ],
	stack(T).

addr2line(SO+Offset, Human) :-
	location(SO, Offset, Human), !.
addr2line(SO+nil, SO) :- !.
addr2line(SO+Offset, Human) :-
	format(string(Cmd), 'addr2line -fe "~w" 0x~16r', [SO, Offset]),
	setup_call_cleanup(
	    open(pipe(Cmd), read, In),
	    read_string(In, _, Reply),
	    close(In)),
	split_string(Reply, "\n", "", [Func,Location|_]), !,
	format(atom(Human), '~w() at ~w', [Func, Location]),
	asserta(location(SO, Offset, Human)).
addr2line(Spec, Spec).
