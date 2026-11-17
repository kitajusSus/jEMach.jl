# ---------------------------------------------------------------------------
# AST scope & free-variable analyzer
# ---------------------------------------------------------------------------

function _is_global_or_type(sym::Symbol)::Bool
    for m in (Main, Base, Core)
        if Base.invokelatest(isdefined, m, sym)
            try
                v = Base.invokelatest(getfield, m, sym)
                (v isa Function || v isa DataType || v isa UnionAll || v isa Module) && return true
            catch
            end
        end
    end
    return false
end

function _bind_ast_lhs!(lhs, target_set::Set{Symbol})
    if lhs isa Symbol
        push!(target_set, lhs)
    elseif lhs isa Expr
        if lhs.head in (:tuple, :parameters)
            for a in lhs.args
                _bind_ast_lhs!(a, target_set)
            end
        elseif lhs.head in (:(::), :(=), :...) && !isempty(lhs.args)
            _bind_ast_lhs!(lhs.args[1], target_set)
        end
    end
    return target_set
end

function _collect_for_bindings!(spec, assigned::Set{Symbol}, referenced::Set{Symbol}, outer_scope::Set{Symbol}, loop_scope::Set{Symbol})
    if spec isa Expr && spec.head == :(=) && length(spec.args) >= 2
        _collect_ast_symbols!(spec.args[2], assigned, referenced, outer_scope)
        _bind_ast_lhs!(spec.args[1], loop_scope)
    elseif spec isa Expr && spec.head == :block
        for item in spec.args
            item isa LineNumberNode && continue
            _collect_for_bindings!(item, assigned, referenced, outer_scope, loop_scope)
        end
    end
    return loop_scope
end

function _is_func_sig_lhs(lhs)::Bool
    while lhs isa Expr && lhs.head in (:where, :(::)) && !isempty(lhs.args)
        lhs = lhs.args[1]
    end
    return lhs isa Expr && lhs.head in (:call, :tuple)
end

function _visit_function_def!(sig, body_args, assigned::Set{Symbol}, referenced::Set{Symbol}, local_scope::Set{Symbol})
    new_scope = copy(local_scope)
    while sig isa Expr && sig.head == :where && !isempty(sig.args)
        for i in 2:length(sig.args)
            _bind_ast_lhs!(sig.args[i], new_scope)
        end
        sig = sig.args[1]
    end
    if sig isa Symbol
        push!(assigned, sig)
    elseif sig isa Expr && sig.head == :call && !isempty(sig.args)
        sig.args[1] isa Symbol && push!(assigned, sig.args[1])
        for a in sig.args[2:end]
            if a isa Expr && a.head == :kw && length(a.args) >= 2
                _collect_ast_symbols!(a.args[2], assigned, referenced, new_scope)
            end
            _bind_ast_lhs!(a, new_scope)
        end
    elseif sig isa Expr && sig.head == :tuple
        _bind_ast_lhs!(sig, new_scope)
    end
    for a in body_args
        _collect_ast_symbols!(a, assigned, referenced, new_scope)
    end
    return nothing
end

function _collect_ast_symbols!(ex, assigned::Set{Symbol}, referenced::Set{Symbol}, local_scope::Set{Symbol} = Set{Symbol}())
    if ex isa QuoteNode || ex isa LineNumberNode
        return nothing
    elseif ex isa Symbol
        !(ex in local_scope) && !(ex in assigned) && push!(referenced, ex)
        return nothing
    elseif !(ex isa Expr)
        return nothing
    end

    h = ex.head
    if h in (:quote, :inert, :using, :import, :export, :meta)
        return nothing
    elseif h == :(=)
        lhs = ex.args[1]
        if _is_func_sig_lhs(lhs) && !(lhs isa Expr && lhs.head == :tuple)
            _visit_function_def!(lhs, ex.args[2:end], assigned, referenced, local_scope)
        else
            length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, local_scope)
            if lhs isa Symbol || (lhs isa Expr && lhs.head in (:tuple, :(::)))
                _bind_ast_lhs!(lhs, assigned)
            else
                _collect_ast_symbols!(lhs, assigned, referenced, local_scope)
            end
        end
    elseif h == :kw
        length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, local_scope)
    elseif h == :parameters
        for a in ex.args
            if a isa Expr && a.head == :kw
                length(a.args) >= 2 && _collect_ast_symbols!(a.args[2], assigned, referenced, local_scope)
            else
                _collect_ast_symbols!(a, assigned, referenced, local_scope)
            end
        end
    elseif h == :(->)
        new_scope = copy(local_scope)
        length(ex.args) >= 1 && _bind_ast_lhs!(ex.args[1], new_scope)
        length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, new_scope)
    elseif h == :function
        if !isempty(ex.args)
            _visit_function_def!(ex.args[1], ex.args[2:end], assigned, referenced, local_scope)
        end
    elseif h in (:generator, :comprehension)
        new_scope = copy(local_scope)
        if h == :comprehension && length(ex.args) == 1 && ex.args[1] isa Expr && ex.args[1].head in (:generator, :flatten)
            _collect_ast_symbols!(ex.args[1], assigned, referenced, local_scope)
        else
            for i in 2:length(ex.args)
                iter_spec = ex.args[i]
                if iter_spec isa Expr && iter_spec.head == :filter
                    for j in 2:length(iter_spec.args)
                        _collect_for_bindings!(iter_spec.args[j], assigned, referenced, local_scope, new_scope)
                    end
                    !isempty(iter_spec.args) && _collect_ast_symbols!(iter_spec.args[1], assigned, referenced, new_scope)
                else
                    _collect_for_bindings!(iter_spec, assigned, referenced, local_scope, new_scope)
                end
            end
            !isempty(ex.args) && _collect_ast_symbols!(ex.args[1], assigned, referenced, new_scope)
        end
    elseif h == :for
        new_scope = copy(local_scope)
        length(ex.args) >= 1 && _collect_for_bindings!(ex.args[1], assigned, referenced, local_scope, new_scope)
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, new_scope)
        end
    elseif h == :while
        new_scope = copy(local_scope)
        for a in ex.args
            _collect_ast_symbols!(a, assigned, referenced, new_scope)
        end
    elseif h == :let
        new_scope = copy(local_scope)
        if length(ex.args) >= 1
            binds = ex.args[1]
            bind_list = (binds isa Expr && binds.head == :block) ? binds.args : Any[binds]
            for b in bind_list
                b isa LineNumberNode && continue
                if b isa Expr && b.head == :(=)
                    length(b.args) >= 2 && _collect_ast_symbols!(b.args[2], assigned, referenced, new_scope)
                    _bind_ast_lhs!(b.args[1], new_scope)
                elseif b isa Symbol
                    push!(new_scope, b)
                end
            end
        end
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, new_scope)
        end
    elseif h == :local
        for a in ex.args
            if a isa Expr && a.head == :(=)
                length(a.args) >= 2 && _collect_ast_symbols!(a.args[2], assigned, referenced, local_scope)
                _bind_ast_lhs!(a.args[1], local_scope)
            elseif a isa Symbol
                push!(local_scope, a)
            end
        end
    elseif h == :macrocall
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, local_scope)
        end
    elseif h == :.
        !isempty(ex.args) && _collect_ast_symbols!(ex.args[1], assigned, referenced, local_scope)
    else
        for a in ex.args
            _collect_ast_symbols!(a, assigned, referenced, local_scope)
        end
    end
    return nothing
end

const _LITERAL_CALL_OPS = Set([:(:), :+, :-, :*, :/, :^, :vect, :vcat, :hcat, :tuple, :(=>)])

function _is_literal_expr(ex)::Bool
    if ex isa Number || ex isa AbstractString || ex isa Char || ex isa Bool || ex isa QuoteNode
        return true
    elseif ex isa Symbol
        return ex in (:nothing, :missing, :true, :false, :pi, :ℯ, :im)
    elseif ex isa Expr
        if ex.head in (:vect, :vcat, :hcat, :row, :tuple, :braces)
            return all(_is_literal_expr, ex.args)
        elseif ex.head == :call && !isempty(ex.args) && ex.args[1] in _LITERAL_CALL_OPS
            return all(_is_literal_expr, ex.args[2:end])
        elseif ex.head == :... && length(ex.args) == 1
            return _is_literal_expr(ex.args[1])
        end
    end
    return false
end

function _default_param_str(sym::Symbol)::Tuple{String, Bool}
    if Base.invokelatest(isdefined, Main, sym)
        val = try
            Base.invokelatest(getfield, Main, sym)
        catch
            nothing
        end
        if !isnothing(val)
            try
                rep = Base.invokelatest(repr, val)
                if length(rep) <= 80 && !occursin('\n', rep)
                    return ("$(sym) = $(rep)", true)
                end
            catch
            end
            return ("$(sym) = Main.$(sym)", true)
        end
    end
    return (string(sym), false)
end

function _is_import_expr(ex)::Bool
    return ex isa Expr && ex.head in (:using, :import)
end

function _collect_imported_bindings!(ex, imported_syms::Set{Symbol})
    !_is_import_expr(ex) && return nothing
    for a in ex.args
        !(a isa Expr) && continue
        if a.head == :(:) && length(a.args) >= 2
            for item in a.args[2:end]
                if item isa Expr && item.head == :. && !isempty(item.args) && item.args[end] isa Symbol
                    push!(imported_syms, item.args[end])
                elseif item isa Expr && item.head == :as && length(item.args) >= 2 && item.args[2] isa Symbol
                    push!(imported_syms, item.args[2])
                end
            end
        elseif a.head == :as && length(a.args) >= 2 && a.args[2] isa Symbol
            push!(imported_syms, a.args[2])
        elseif a.head == :. && !isempty(a.args) && a.args[end] isa Symbol
            push!(imported_syms, a.args[end])
        end
    end
    return nothing
end

function _extract_imports_and_body(clean_cmds::Vector{String})
    import_stmts = String[]
    seen_imports = Set{String}()
    body_cmds = String[]
    imported_syms = Set{Symbol}()

    push_import!(s::AbstractString) = begin
        norm = String(strip(s))
        if !isempty(norm) && !(norm in seen_imports)
            push!(seen_imports, norm)
            push!(import_stmts, norm)
        end
    end

    for cmd in clean_cmds
        ex = try
            Meta.parseall(cmd)
        catch
            nothing
        end
        if !(ex isa Expr)
            push!(body_cmds, cmd)
            continue
        end
        top_stmts = [a for a in ex.args if !(a isa LineNumberNode)]
        if !any(_is_import_expr, top_stmts)
            push!(body_cmds, cmd)
            continue
        end

        for stmt in top_stmts
            _is_import_expr(stmt) && _collect_imported_bindings!(stmt, imported_syms)
        end

        if all(_is_import_expr, top_stmts)
            for stmt in top_stmts
                push_import!(string(stmt))
            end
            continue
        end

        # Mixed block: strip standalone `using`/`import` lines cleanly so remaining lines keep formatting
        kept_lines = String[]
        raw_lines = split(cmd, '\n')
        line_clean_ok = true
        extracted_from_lines = String[]
        for ln in raw_lines
            sln = strip(ln)
            if startswith(sln, "using ") || startswith(sln, "using\t") || startswith(sln, "import ") || startswith(sln, "import\t")
                lp = try
                    Meta.parseall(sln)
                catch
                    nothing
                end
                lstmts = (lp isa Expr) ? [a for a in lp.args if !(a isa LineNumberNode)] : Any[]
                if !isempty(lstmts) && all(_is_import_expr, lstmts)
                    for stmt in lstmts
                        push!(extracted_from_lines, string(stmt))
                    end
                    continue
                else
                    line_clean_ok = false
                    break
                end
            end
            push!(kept_lines, String(ln))
        end

        if line_clean_ok && !isempty(extracted_from_lines)
            for imp in extracted_from_lines
                push_import!(imp)
            end
            rem = rstrip(join(kept_lines, "\n"))
            !isempty(strip(rem)) && push!(body_cmds, String(rem))
        else
            rem_stmts = String[]
            for stmt in top_stmts
                if _is_import_expr(stmt)
                    push_import!(string(stmt))
                else
                    push!(rem_stmts, string(stmt))
                end
            end
            !isempty(rem_stmts) && push!(body_cmds, join(rem_stmts, "\n"))
        end
    end

    return import_stmts, body_cmds, imported_syms
end
