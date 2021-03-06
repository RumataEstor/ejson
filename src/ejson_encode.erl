%%%-----------------------------------------------------------------------------
%%% Copyright (C) 2013-2014, Richard Jonas <mail@jonasrichard.hu>
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%% @author Richard Jonas <mail@jonasrichard.hu>
%%% @doc
%%% ejson encoder module
%%% @end
%%%-----------------------------------------------------------------------------
-module(ejson_encode).

-export([encode/2]).

-spec encode(term(), list()) -> {ok, jsx:json_term()} |
                                {error, {duplicate_records, list(atom())}} |
                                {error, {duplicate_fields, list(binary())}}. 
encode(Value, Opts) ->
    case validate_rules(Opts) of
        ok ->
            case encode1(Value, Opts) of
                {error, _} = Error ->
                    Error;
                Result ->
                    {ok, Result}
            end;
        Error2 ->
            Error2
    end.

%% Convert a record
encode1(Tuple, Opts) when is_tuple(Tuple) andalso is_atom(element(1, Tuple)) ->
    [RecordName | Values] = tuple_to_list(Tuple),
    %% Get field rules
    case ejson_util:get_fields(RecordName, Opts) of
        {error, _} = Error ->
            Error;
        Fields ->
            %% Convert each values
            case convert(ejson_util:zip(Fields, Values), Tuple, Opts, []) of
                {error, _} = Error ->
                    Error;
                AttrList ->
                    lists:reverse(AttrList)
            end
    end;
encode1(Value, Opts) when is_list(Value) ->
    [encode1(Val, Opts) || Val <- Value];
encode1(Value, _Opts) when is_number(Value) orelse is_boolean(Value) ->
    Value;
encode1(undefined, _Opts) ->
    null.

validate_rules(Opts) ->
    RecordNames = [element(1, Opt) || Opt <- Opts],
    case lists:sort(RecordNames) -- lists:usort(RecordNames) of
        [] ->
            case check_duplicate_fields(Opts) of
                [] ->
                    ok;
                Fields ->
                    {error, {duplicate_fields, Fields}}
            end;
        Records ->
            {error, {duplicate_records, lists:usort(Records)}}
    end.

convert([], _Tuple, _Opts, Result) ->
    Result;
convert([{Name, Value} | T], Tuple, Opts, Result) ->
    case maybe_pre_process(Name, Tuple, Value) of
        {ok, PreProcessed} ->
            case apply_rule(Name, PreProcessed, Opts) of
                undefined ->
                    convert(T, Tuple, Opts, Result);
                {error, _} = Error ->
                    Error;
                {ok, {NewName, NewValue}} when is_atom(NewName) ->
                    convert(T, Tuple, Opts, [{atom_to_binary(NewName, utf8),
                                              NewValue} | Result]);
                {ok, {NewName, NewValue}} ->
                    convert(T, Tuple, Opts, [{list_to_binary(NewName), NewValue} |
                                             Result])
            end;
        {error, _} = Error2 ->
            Error2
    end.

%% Generate jsx attribute from ejson field
apply_rule(Name, Value, Opts) ->
    case Name of
        skip ->
            undefined;
        {number, AttrName} ->
            number_rule(AttrName, Value);
        {number, AttrName, _FieldOpts} ->
            number_rule(AttrName, Value);
        {boolean, AttrName} ->
            boolean_rule(AttrName, Value);
        {boolean, AttrName, _FieldOpts} ->
            boolean_rule(AttrName, Value);
        {atom, AttrName} ->
            atom_rule(AttrName, Value);
        {atom, AttrName, _FieldOpts} ->
            atom_rule(AttrName, Value);
        {binary, AttrName} ->
            binary_rule(AttrName, Value);
        {binary, AttrName, _FieldOpts} ->
            binary_rule(AttrName, Value);
        {string, AttrName} ->
            string_rule(AttrName, Value);
        {string, AttrName, _FieldOpts} ->
            string_rule(AttrName, Value);
        {record, AttrName} ->
            record_rule(AttrName, Value, [], Opts);
        {record, AttrName, FieldOpts} ->
            record_rule(AttrName, Value, FieldOpts, Opts);
        {list, AttrName} ->
            mixed_list_rule(AttrName, Value, Opts);
        {list, AttrName, _FieldOpts} ->
            list_rule(AttrName, Value, Opts);
        {generic, AttrName, _FieldOpts} ->
            %% Generic encoding is handled in pre_process phase
            {ok, {AttrName, Value}};
        {const, AttrName, Const} ->
            {ok, {AttrName, encode1(Const, Opts)}};
        AttrName ->
            {error, {invalid_field_rule, AttrName, Name}}
    end.

boolean_rule(AttrName, undefined) ->
    {ok, {AttrName, null}};
boolean_rule(AttrName, Value) when is_boolean(Value) ->
    {ok, {AttrName, Value}};
boolean_rule(AttrName, Value) ->
    {error, {boolean_value_expected, AttrName, Value}}.

number_rule(AttrName, undefined) ->
    {ok, {AttrName, null}};
number_rule(AttrName, Value) when is_number(Value) ->
    {ok, {AttrName, Value}};
number_rule(AttrName, Value) ->
    {error, {numeric_value_expected, AttrName, Value}}.

atom_rule(AttrName, undefined) ->
    {ok, {AttrName, null}};
atom_rule(AttrName, Value) when is_atom(Value) ->
    {ok, {AttrName, atom_to_binary(Value, utf8)}};
atom_rule(AttrName, Value) ->
    {error, {atom_value_expected, AttrName, Value}}.

binary_rule(AttrName, undefined) ->
    {ok, {AttrName, null}};
binary_rule(AttrName, Value) when is_binary(Value) ->
    {ok, {AttrName, Value}};
binary_rule(AttrName, Value) ->
    {error, {binary_value_expected, AttrName, Value}}.

string_rule(AttrName, undefined) ->
    {ok, {AttrName, null}};
string_rule(AttrName, Value) when is_list(Value) ->
    {ok, {AttrName, unicode:characters_to_binary(Value)}};
string_rule(AttrName, Value) ->
    {error, {string_value_expected, AttrName, Value}}.

record_rule(AttrName, undefined, _FieldOpts, _Opts) ->
    {ok, {AttrName, null}};
record_rule(AttrName, Value, FieldOpts, Opts) when is_tuple(Value) ->
    case lists:keyfind(type, 1, FieldOpts) of
        false ->
            %% If record type is not specified add __rec meta data
            R = encode1(Value, Opts),
            {ok, {AttrName, add_rec_type(element(1, Value), R)}};
        _ ->
            {ok, {AttrName, encode1(Value, Opts)}}
    end;
record_rule(AttrName, Value, _FieldOpts, _Opts) ->
    {error, {record_value_expected, AttrName, Value}}.

list_rule(AttrName, undefined, _Opts) ->
    {ok, {AttrName, null}};
list_rule(AttrName, Value, Opts) when is_list(Value) ->
    List = [encode1(V, Opts) || V <- Value],
    {ok, {AttrName, List}};
list_rule(AttrName, Value, _Opts) ->
    {error, {list_value_expected, AttrName, Value}}.

mixed_list_rule(AttrName, undefined, _Opts) ->
    {ok, {AttrName, null}};
mixed_list_rule(AttrName, Value, Opts) when is_list(Value) ->
    try lists:map(
          fun(N) when is_number(N) ->
                  N;
             (B) when is_boolean(B) ->
                  B;
             (T) when is_tuple(T) ->
                  Rec = element(1, T),
                  case encode1(T, Opts) of
                      {error, R} ->
                          throw(R);
                      AttrList ->
                          add_rec_type(Rec, AttrList)
                  end;
             (E) ->
                  throw({invalid_list_item, E})
          end, Value) of
        List ->
            {ok, {AttrName, List}}
    catch
        E:R ->
            {error, AttrName, E, R}
    end;
mixed_list_rule(AttrName, Value, _Opts) ->
    {error, {list_value_expected, AttrName, Value}}.

maybe_pre_process({const, _Name, _Const}, _Tuple, Value) ->
    {ok, Value};
maybe_pre_process({Type, Name, FieldOpts}, Tuple, Value) ->
    case lists:keyfind(pre_encode, 1, FieldOpts) of
        false ->
            case Type of
                generic ->
                    %% In case of generic pre_encode is mandatory
                    {error, {no_pre_encode, Name, Value}};
                _ ->
                    {ok, Value}
            end;
        {pre_encode, {M, F}} ->
            try erlang:apply(M, F, [Tuple, Value]) of
                Val ->
                    {ok, Val}
            catch
                E:R ->
                    {error, {Name, E, R}}
            end
    end;
maybe_pre_process(_Rule, _Tuple, Value) ->
    {ok, Value}.

add_rec_type(Type, List) ->
    [{<<"__rec">>, atom_to_binary(Type, utf8)} | List].

%% Check duplicate fields in record definition. It gives false if each field is
%% unique, otherwise it gives the duplicate field names.
-spec check_duplicate_fields(list()) -> false | list(atom()).
check_duplicate_fields([]) ->
    [];
check_duplicate_fields([Rule | Rules]) ->
    [_ | Fields] = tuple_to_list(Rule),
    FieldNames = [field_name(Field) || Field <- Fields],
    Names = [F || F <- FieldNames, F =/= undefined],
    case lists:sort(Names) -- lists:usort(Names) of
        [] ->
            check_duplicate_fields(Rules);
        DupFields ->
            DupFields
    end.

field_name(Field) ->
    case ejson_util:get_field_name(Field) of
        undefined ->
            undefined;
        Name when is_atom(Name) ->
            ejson_util:atom_to_binary_cc(Name);
        List when is_list(List) ->
            list_to_binary(List)
    end.
