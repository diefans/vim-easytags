" Vim auto-load script
" Author: Peter Odding <peter@peterodding.com>
" Last Change: May 25, 2013
" URL: http://peterodding.com/code/vim/easytags/

let g:xolox#easytags#version = '3.3.6'

" Public interface through (automatic) commands. {{{1

function! xolox#easytags#register(global) " {{{2
  " Parse the &tags option and get a list of all tags files *including
  " non-existing files* (this is why we can't just call tagfiles()).
  let tagfiles = xolox#misc#option#split_tags(&tags)
  let expanded = map(copy(tagfiles), 'resolve(expand(v:val))')
  " Add the filename to the &tags option when the user hasn't done so already.
  let tagsfile = a:global ? g:easytags_file : xolox#easytags#get_tagsfile()
  if index(expanded, xolox#misc#path#absolute(tagsfile)) == -1
    " This is a real mess because of bugs in Vim?! :let &tags = '...' doesn't
    " work on UNIX and Windows, :set tags=... doesn't work on Windows. What I
    " mean with "doesn't work" is that tagfiles() == [] after the :let/:set
    " command even though the tags file exists! One easy way to confirm that
    " this is a bug in Vim is to type :set tags= then press <Tab> followed by
    " <CR>. Now you entered the exact same value that the code below also did
    " but suddenly Vim sees the tags file and tagfiles() != [] :-S
    call add(tagfiles, tagsfile)
    let value = xolox#misc#option#join_tags(tagfiles)
    let cmd = (a:global ? 'set' : 'setl') . ' tags=' . escape(value, '\ ')
    if xolox#misc#os#is_win() && v:version < 703
      " TODO How to clear the expression from Vim's status line?
      call feedkeys(":" . cmd . "|let &ro=&ro\<CR>", 'n')
    else
      execute cmd
    endif
  endif
endfunction

" The localtime() when the CursorHold event last fired.
let s:last_automatic_run = 0

function! xolox#easytags#autoload(event) " {{{2
  try
    if exists('g:SessionLoad') && a:event == 'BufReadPost'
      " If a session is being loaded, we won't update the tags for files that
      " are loaded in the session because this disrupts the session loading...
      call xolox#misc#msg#debug("easytags.vim %s: Skipping update because session is being loaded.", g:xolox#easytags#version)
      return
    endif
    let do_update = xolox#misc#option#get('easytags_auto_update', 1)
    let do_highlight = xolox#misc#option#get('easytags_auto_highlight', 1) && &eventignore !~? '\<syntax\>'
    " Don't execute this function for unsupported file types (doesn't load
    " the list of file types if updates and highlighting are both disabled).
    if (do_update || do_highlight) && !empty(xolox#easytags#select_supported_filetypes(&ft))
      if a:event =~? 'cursorhold'
        " Only for the CursorHold automatic command: check for unreasonable
        " &updatetime values. The minimum value 4000 is kind of arbitrary
        " (apart from being Vim's default) so I made it configurable.
        let updatetime_min = xolox#misc#option#get('easytags_updatetime_min', 4000)
        if &updatetime < updatetime_min
          if s:last_automatic_run == 0
            " Warn once about the low &updatetime value?
            if xolox#misc#option#get('easytags_updatetime_warn', 1)
              call xolox#misc#msg#warn("easytags.vim %s: The 'updatetime' option has an unreasonably low value, so I'll start compensating (see the easytags_updatetime_min option).", g:xolox#easytags#version)
            endif
            let s:last_automatic_run = localtime()
          else
            let next_scheduled_run = s:last_automatic_run + max([1, updatetime_min / 1000])
            if localtime() < next_scheduled_run
              " It's not our time yet; wait for the next event.
              call xolox#misc#msg#debug("easytags.vim %s: Skipping this beat of 'updatetime' to compensate for low value.", g:xolox#easytags#version)
              " Shortcut to break out of xolox#easytags#autoload().
              return
            else
              call xolox#misc#msg#debug("easytags.vim %s: This is our beat of 'updatetime'!", g:xolox#easytags#version)
              let s:last_automatic_run = localtime()
            endif
          endif
        endif
      endif
      " Update entries for current file in tags file?
      if do_update
        let pathname = s:resolve(expand('%:p'))
        if pathname != ''
          let tags_outdated = getftime(pathname) > getftime(xolox#easytags#get_tagsfile())
          if tags_outdated || !xolox#easytags#file_has_tags(pathname)
            call xolox#easytags#update(1, 0, [])
          endif
        endif
      endif
      " Apply highlighting of tags to current buffer?
      if do_highlight
        if !exists('b:easytags_last_highlighted')
          call xolox#easytags#highlight()
        else
          for tagfile in tagfiles()
            if getftime(tagfile) > b:easytags_last_highlighted
              call xolox#easytags#highlight()
              break
            endif
          endfor
        endif
        let b:easytags_last_highlighted = localtime()
      endif
    endif
  catch
    call xolox#misc#msg#warn("easytags.vim %s: %s (at %s)", g:xolox#easytags#version, v:exception, v:throwpoint)
  endtry
endfunction

function! xolox#easytags#update(silent, filter_tags, filenames) " {{{2
  try
    let starttime = xolox#misc#timer#start()
    " Phase #1: Prepare to run Exuberant Ctags and store all of the state
    " required to execute Exuberant Ctags in a dictionary called "context".
    let context = s:update_phase_1(a:silent, a:filter_tags, a:filenames)
    " Store the time when the update process was started inside the context.
    let context['starttime'] = starttime
    " Remember whether the user explicitly executed :UpdateTags or we were
    " executed by an automatic command.
    let context['silent'] = a:silent
    " Generate the Vim command needed to start phase #2.
    let vim_command = printf('let &rtp = %s | call xolox#easytags#update_remote(%s)', string(&rtp), string(context))
    call xolox#misc#msg#debug("easytags.vim %s: Generated asynchronous Vim command: %s", g:xolox#easytags#version, vim_command)
    " Generate the shell command needed to start phase #2.
    let shell_command = printf('%s -u NONE -U NONE --noplugin -n -N -i NONE --cmd %s',
          \ xolox#misc#escape#shell(xolox#misc#os#find_vim()),
          \ xolox#misc#escape#shell(vim_command))
    call xolox#misc#msg#debug("easytags.vim %s: Generated asynchronous shell command: %s", g:xolox#easytags#version, shell_command)
    " Phase #2: Update the tags asynchronously in a background process.
    let result = xolox#misc#os#exec({'command': shell_command, 'async': 1})
    " Report to the user what's happening.
    call xolox#misc#timer#force("easytags.vim %s: Started asynchronous tag update in %s ..", g:xolox#easytags#version, starttime)
  catch
    call xolox#misc#msg#warn("easytags.vim %s: %s (at %s)", g:xolox#easytags#version, v:exception, v:throwpoint)
    return {}
  endtry
endfunction

function! s:update_phase_1(silent, filter_tags, filenames) " {{{3
  let starttime = xolox#misc#timer#start()
  let have_args = !empty(a:filenames)
  let tagsfile = xolox#easytags#get_tagsfile()
  let context = s:create_context({
        \ 'filter_tags': a:filter_tags,
        \ 'have_args': have_args,
        \ 'tagsfile': tagsfile })
  let cfile = s:check_cfile(a:silent, a:filter_tags, have_args)
  let context['cmdline'] = s:prep_cmdline(cfile, tagsfile, a:filenames, context)
  return context
endfunction

function! s:update_phase_2(context) " {{{3
  let output = s:run_ctags(a:context['cmdline'])
  let starttime = xolox#misc#timer#start()
  if a:context['have_args'] && !empty(a:context['by_filetype'])
    " TODO Get the headers from somewhere?!
    call s:save_by_filetype(a:context['filter_tags'], [], output, a:context)
  else
    call s:filter_merge_tags(a:context['filter_tags'], a:context['tagsfile'], output, a:context)
  endif
  call xolox#misc#timer#stop("easytags.vim %s: Finished merging tags in %s.", g:xolox#easytags#version, starttime)
  return len(output)
endfunction

function! s:check_cfile(silent, filter_tags, have_args) " {{{3
  if a:have_args
    return ''
  endif
  let silent = a:silent || a:filter_tags
  if xolox#misc#option#get('easytags_autorecurse', 0)
    let cdir = s:resolve(expand('%:p:h'))
    if !isdirectory(cdir)
      if silent | return '' | endif
      throw "The directory of the current file doesn't exist yet!"
    endif
    return cdir
  endif
  let cfile = s:resolve(expand('%:p'))
  if cfile == '' || !filereadable(cfile)
    if silent | return '' | endif
    throw "You'll need to save your file before using :UpdateTags!"
  elseif g:easytags_ignored_filetypes != '' && &ft =~ g:easytags_ignored_filetypes
    if silent | return '' | endif
    throw "The " . string(&ft) . " file type is explicitly ignored."
  elseif empty(xolox#easytags#select_supported_filetypes(&ft))
    if silent | return '' | endif
    if empty(&ft)
      throw "Please set the buffer's file type before running Exuberant Ctags!"
    else
      throw "Exuberant Ctags doesn't support the " . string(&ft) . " file type!"
    endif
  endif
  return cfile
endfunction

function! s:prep_cmdline(cfile, tagsfile, arguments, context) " {{{3
  let languages = xolox#misc#option#get('easytags_languages', {})
  let applicable_filetypes = xolox#easytags#select_supported_filetypes(&ft)
  let ctags_language_name = xolox#easytags#to_ctags_ft(applicable_filetypes[0])
  let language = get(languages, ctags_language_name, {})
  if empty(language)
    let program = xolox#misc#option#get('easytags_cmd')
    let cmdline = [program, '--fields=+l', '--c-kinds=+p', '--c++-kinds=+p', '--sort=no', '-f-']
    if xolox#misc#option#get('easytags_include_members', 0)
      call add(cmdline, '--extra=+q')
    endif
  else
    let program = get(language, 'cmd', xolox#misc#option#get('easytags_cmd'))
    if empty(program)
      call xolox#misc#msg#warn("easytags.vim %s: No 'cmd' defined for language '%s', and also no global default!", g:xolox#easytags#version, ctags_language_name)
      return
    endif
    let cmdline = [program] + get(language, 'args', [])
    call add(cmdline, xolox#misc#escape#shell(get(language, 'stdout_opt', '-f-')))
  endif
  let have_args = 0
  if a:cfile != ''
    if xolox#misc#option#get('easytags_autorecurse', 0)
      call add(cmdline, empty(language) ? '-R' : xolox#misc#escape#shell(get(language, 'recurse_flag', '-R')))
      call add(cmdline, xolox#misc#escape#shell(a:cfile))
    else
      if empty(language)
        " TODO Should --language-force distinguish between C and C++?
        " TODO --language-force doesn't make sense for JavaScript tags in HTML files?
        let filetype = xolox#easytags#to_ctags_ft(applicable_filetypes[0])
        call add(cmdline, xolox#misc#escape#shell('--language-force=' . filetype))
      endif
      call add(cmdline, xolox#misc#escape#shell(a:cfile))
    endif
    let have_args = 1
  else
    for arg in a:arguments
      if arg =~ '^-'
        call add(cmdline, arg)
        let have_args = 1
      else
        let matches = split(expand(arg), "\n")
        if !empty(matches)
          call map(matches, 'xolox#misc#escape#shell(s:canonicalize(v:val, a:context))')
          call extend(cmdline, matches)
          let have_args = 1
        endif
      endif
    endfor
  endif
  " No need to run Exuberant Ctags without any filename arguments!
  return have_args ? join(cmdline) : ''
endfunction

function! s:run_ctags(cmdline) " {{{3
  let lines = []
  if a:cmdline != ''
    let starttime = xolox#misc#timer#start()
    call xolox#misc#msg#debug("easytags.vim %s: Executing %s.", g:xolox#easytags#version, a:cmdline)
    let lines = xolox#misc#os#exec({'command': a:cmdline})['stdout']
    call xolox#misc#timer#stop("easytags.vim %s: Exuberant Ctags finished in %s.", g:xolox#easytags#version, starttime)
  endif
  return xolox#easytags#parse_entries(lines)
endfunction

function! s:filter_merge_tags(filter_tags, tagsfile, output, context) " {{{3
  let [headers, entries] = xolox#easytags#read_tagsfile(a:tagsfile)
  let filters = []
  " Filter old tags that are to be replaced with the tags in {output}.
  let tagged_files = s:find_tagged_files(a:output, a:context)
  if !empty(tagged_files)
    call add(filters, '!has_key(tagged_files, s:canonicalize(v:val[1], a:context))')
  endif
  " Filter tags for non-existing files?
  if a:filter_tags
    call add(filters, 'filereadable(v:val[1])')
  endif
  let num_old_entries = len(entries)
  if !empty(filters)
    " Apply the filters.
    call filter(entries, join(filters, ' && '))
  endif
  let num_filtered = num_old_entries - len(entries)
  call xolox#misc#msg#debug("easytags.vim %s: Filtered %i/%i tags from output of Exuberant Ctags.", g:xolox#easytags#version, num_filtered, num_old_entries)
  " Merge the old and new tags.
  call extend(entries, a:output)
  " Since we've already read the tags file we might as well cache the tagged
  " files. We do so before saving the tags file so that the items in {entries}
  " are not yet flattened by xolox#easytags#write_tagsfile().
  let fname = s:canonicalize(a:tagsfile, a:context)
  call s:cache_tagged_files_in(fname, getftime(fname), entries, a:context)
  " Now we're ready to save the tags file.
  if !xolox#easytags#write_tagsfile(a:tagsfile, headers, entries)
    let msg = "Failed to write filtered tags file %s!"
    throw printf(msg, fnamemodify(a:tagsfile, ':~'))
  endif
  return num_filtered
endfunction

function! s:find_tagged_files(entries, context) " {{{3
  let tagged_files = {}
  for entry in a:entries
    let filename = s:canonicalize(entry[1], a:context)
    if filename != ''
      if !has_key(tagged_files, filename)
        let tagged_files[filename] = 1
      endif
    endif
  endfor
  return tagged_files
endfunction

function! xolox#easytags#highlight() " {{{2
  try
    " Treat C++ and Objective-C as plain C.
    let filetype = get(s:canonical_aliases, &ft, &ft)
    let tagkinds = get(s:tagkinds, filetype, [])
    if exists('g:syntax_on') && !empty(tagkinds) && !exists('b:easytags_nohl')
      let starttime = xolox#misc#timer#start()
      for tagkind in tagkinds
        let hlgroup_tagged = tagkind.hlgroup . 'Tag'
        " Define style on first run, clear highlighting on later runs.
        if !hlexists(hlgroup_tagged)
          execute 'highlight def link' hlgroup_tagged tagkind.hlgroup
        else
          execute 'syntax clear' hlgroup_tagged
        endif
        if !exists('taglist')
          " Get the list of tags when we need it and remember the results.
          if !has_key(s:aliases, filetype)
            let ctags_filetype = xolox#easytags#to_ctags_ft(filetype)
            let taglist = filter(taglist('.'), "get(v:val, 'language', '') ==? ctags_filetype")
          else
            let aliases = s:aliases[&ft]
            let taglist = filter(taglist('.'), "has_key(aliases, tolower(get(v:val, 'language', '')))")
          endif
        endif
        " Filter a copy of the list of tags to the relevant kinds.
        if has_key(tagkind, 'tagkinds')
          let filter = 'v:val.kind =~ tagkind.tagkinds'
        else
          let filter = tagkind.vim_filter
        endif
        let matches = filter(copy(taglist), filter)
        if matches != []
          " Convert matched tags to :syntax command and execute it.
          let matches = xolox#misc#list#unique(map(matches, 'xolox#misc#escape#pattern(get(v:val, "name"))'))
          let pattern = tagkind.pattern_prefix . '\%(' . join(matches, '\|') . '\)' . tagkind.pattern_suffix
          let template = 'syntax match %s /%s/ containedin=ALLBUT,%s'
          let command = printf(template, hlgroup_tagged, escape(pattern, '/'), xolox#misc#option#get('easytags_ignored_syntax_groups'))
          call xolox#misc#msg#debug("easytags.vim %s: Executing command '%s'.", g:xolox#easytags#version, command)
          try
            execute command
          catch /^Vim\%((\a\+)\)\=:E339/
            let msg = "easytags.vim %s: Failed to highlight %i %s tags because pattern is too big! (%i KB)"
            call xolox#misc#msg#warn(msg, g:xolox#easytags#version, len(matches), tagkind.hlgroup, len(pattern) / 1024)
          endtry
        endif
      endfor
      redraw
      let bufname = expand('%:p:~')
      if bufname == ''
        let bufname = 'unnamed buffer #' . bufnr('%')
      endif
      let msg = "easytags.vim %s: Highlighted tags in %s in %s."
      call xolox#misc#timer#stop(msg, g:xolox#easytags#version, bufname, starttime)
      return 1
    endif
  catch
    call xolox#misc#msg#warn("easytags.vim %s: %s (at %s)", g:xolox#easytags#version, v:exception, v:throwpoint)
  endtry
endfunction

function! xolox#easytags#by_filetype(undo) " {{{2
  try
    if empty(g:easytags_by_filetype)
      throw "Please set g:easytags_by_filetype before running :TagsByFileType!"
    endif
    let context = s:create_context({})
    let global_tagsfile = expand(g:easytags_file)
    let disabled_tagsfile = global_tagsfile . '.disabled'
    if !a:undo
      let [headers, entries] = xolox#easytags#read_tagsfile(global_tagsfile)
      call s:save_by_filetype(0, headers, entries, context)
      call rename(global_tagsfile, disabled_tagsfile)
      let msg = "easytags.vim %s: Finished copying tags from %s to %s! Note that your old tags file has been renamed to %s instead of deleting it, should you want to restore it."
      call xolox#misc#msg#info(msg, g:xolox#easytags#version, g:easytags_file, g:easytags_by_filetype, disabled_tagsfile)
    else
      let headers = []
      let all_entries = []
      for tagsfile in split(glob(g:easytags_by_filetype . '/*'), '\n')
        let [headers, entries] = xolox#easytags#read_tagsfile(tagsfile)
        call extend(all_entries, entries)
      endfor
      call xolox#easytags#write_tagsfile(global_tagsfile, headers, all_entries)
      call xolox#misc#msg#info("easytags.vim %s: Finished copying tags from %s to %s!", g:xolox#easytags#version, g:easytags_by_filetype, g:easytags_file)
    endif
  catch
    call xolox#misc#msg#warn("easytags.vim %s: %s (at %s)", g:xolox#easytags#version, v:exception, v:throwpoint)
  endtry
endfunction

function! s:save_by_filetype(filter_tags, headers, entries, context)
  let filetypes = {}
  let num_invalid = 0
  for entry in a:entries
    let ctags_ft = matchstr(entry[4], '^language:\zs\S\+$')
    if empty(ctags_ft)
      " TODO This triggers on entries where the pattern contains tabs. The
      " interesting thing is that Vim reads these entries fine... Fix it in
      " xolox#easytags#read_tagsfile()?
      let num_invalid += 1
      if &vbs >= 1
        call xolox#misc#msg#debug("easytags.vim %s: Skipping tag without 'language:' field: %s",
              \ g:xolox#easytags#version, string(entry))
      endif
    else
      let vim_ft = xolox#easytags#to_vim_ft(ctags_ft)
      if !has_key(filetypes, vim_ft)
        let filetypes[vim_ft] = []
      endif
      call add(filetypes[vim_ft], entry)
    endif
  endfor
  if num_invalid > 0
    call xolox#misc#msg#warn("easytags.vim %s: Skipped %i lines without 'language:' tag!", g:xolox#easytags#version, num_invalid)
  endif
  let directory = xolox#misc#path#absolute(a:context['by_filetype'])
  for vim_ft in keys(filetypes)
    let tagsfile = xolox#misc#path#merge(directory, vim_ft)
    let existing = filereadable(tagsfile)
    call xolox#misc#msg#debug("easytags.vim %s: Writing %s tags to %s tags file %s.",
          \ g:xolox#easytags#version, len(filetypes[vim_ft]),
          \ existing ? "existing" : "new", tagsfile)
    if !existing
      call xolox#easytags#write_tagsfile(tagsfile, a:headers, filetypes[vim_ft])
    else
      call s:filter_merge_tags(a:filter_tags, tagsfile, filetypes[vim_ft], a:context)
    endif
  endfor
endfunction

" Public supporting functions (might be useful to others). {{{1

function! xolox#easytags#supported_filetypes() " {{{2
  if !exists('s:supported_filetypes')
    let starttime = xolox#misc#timer#start()
    let listing = []
    if !empty(g:easytags_cmd)
      let command = g:easytags_cmd . ' --list-languages'
      let listing = xolox#misc#os#exec({'command': command})['stdout']
    endif
    let s:supported_filetypes = map(copy(listing) + keys(xolox#misc#option#get('easytags_languages', {})), 's:check_filetype(listing, v:val)')
    let msg = "easytags.vim %s: Retrieved %i supported languages in %s."
    call xolox#misc#timer#stop(msg, g:xolox#easytags#version, len(s:supported_filetypes), starttime)
  endif
  return s:supported_filetypes
endfunction

function! s:check_filetype(listing, cline)
  if a:cline !~ '^\w\S*$'
    let msg = "Failed to get supported languages! (output: %s)"
    throw printf(msg, strtrans(join(a:listing, "\n")))
  endif
  return xolox#easytags#to_vim_ft(a:cline)
endfunction

function! xolox#easytags#select_supported_filetypes(vim_ft) " {{{2
  let supported_filetypes = xolox#easytags#supported_filetypes()
  let applicable_filetypes = []
  for ft in split(&filetype, '\.')
    if index(supported_filetypes, ft) >= 0
      call add(applicable_filetypes, ft)
    endif
  endfor
  return applicable_filetypes
endfunction

function! xolox#easytags#read_tagsfile(tagsfile) " {{{2
  " I'm not sure whether this is by design or an implementation detail but
  " it's possible for the "!_TAG_FILE_SORTED" header to appear after one or
  " more tags and Vim will apparently still use the header! For this reason
  " the xolox#easytags#write_tagsfile() function should also recognize it,
  " otherwise Vim might complain with "E432: Tags file not sorted".
  let headers = []
  let entries = []
  let num_invalid = 0
  for line in readfile(a:tagsfile)
    if line =~# '^!_TAG_'
      call add(headers, line)
    else
      let entry = xolox#easytags#parse_entry(line)
      if !empty(entry)
        call add(entries, entry)
      else
        let num_invalid += 1
      endif
    endif
  endfor
  if num_invalid > 0
    call xolox#misc#msg#warn("easytags.vim %s: Ignored %i invalid line(s) in %s!", g:xolox#easytags#version, num_invalid, a:tagsfile)
  endif
  return [headers, entries]
endfunction

function! xolox#easytags#parse_entry(line) " {{{2
  let fields = split(a:line, '\t')
  return len(fields) >= 3 ? fields : []
endfunction

function! xolox#easytags#parse_entries(lines) " {{{2
  call map(a:lines, 'xolox#easytags#parse_entry(v:val)')
  return filter(a:lines, '!empty(v:val)')
endfunction

function! xolox#easytags#write_tagsfile(tagsfile, headers, entries) " {{{2
  " This function always sorts the tags file but understands "foldcase".
  let sort_order = 1
  for line in a:headers
    if match(line, '^!_TAG_FILE_SORTED\t2') == 0
      let sort_order = 2
    endif
  endfor
  call map(a:entries, 's:join_entry(v:val)')
  if sort_order == 1
    call sort(a:entries)
  else
    call sort(a:entries, function('s:foldcase_compare'))
  endif
  let lines = []
  if xolox#misc#os#is_win()
    " Exuberant Ctags on Windows requires \r\n but Vim's writefile() doesn't add them!
    for line in a:headers
      call add(lines, line . "\r")
    endfor
    for line in a:entries
      call add(lines, line . "\r")
    endfor
  else
    call extend(lines, a:headers)
    call extend(lines, a:entries)
  endif
  let tempname = a:tagsfile . '.easytags.tmp'
  return writefile(lines, tempname) == 0 && rename(tempname, a:tagsfile) == 0
endfunction

function! s:join_entry(value)
  return type(a:value) == type([]) ? join(a:value, "\t") : a:value
endfunction

function! s:foldcase_compare(a, b)
  let a = toupper(a:a)
  let b = toupper(a:b)
  return a == b ? 0 : a ># b ? 1 : -1
endfunction

function! xolox#easytags#file_has_tags(filename) " {{{2
  " Check whether the given source file occurs in one of the tags files known
  " to Vim. This function might not always give the right answer because of
  " caching, but for the intended purpose that's no problem: When editing an
  " existing file which has no tags defined the plug-in will run Exuberant
  " Ctags to update the tags, *unless the file has already been tagged*.
  call s:cache_tagged_files()
  return has_key(s:tagged_files, s:resolve(a:filename))
endfunction

if !exists('s:tagged_files')
  let s:tagged_files = {}
  let s:known_tagfiles = {}
endif

function! s:cache_tagged_files() " {{{3
  if empty(s:tagged_files)
    " Initialize the cache of tagged files on first use. After initialization
    " we'll only update the cache when we're reading a tags file from disk for
    " other purposes anyway (so the cache doesn't introduce too much overhead).
    let starttime = xolox#misc#timer#start()
    let context = s:create_context({})
    for tagsfile in tagfiles()
      if !filereadable(tagsfile)
        call xolox#misc#msg#warn("easytags.vim %s: Skipping unreadable tags file %s!", g:xolox#easytags#version, tagsfile)
      else
        let fname = s:canonicalize(tagsfile, context)
        let ftime = getftime(fname)
        if get(s:known_tagfiles, fname, 0) != ftime
          let [headers, entries] = xolox#easytags#read_tagsfile(fname)
          call s:cache_tagged_files_in(fname, ftime, entries, context)
        endif
      endif
    endfor
    call xolox#misc#timer#stop("easytags.vim %s: Initialized cache of tagged files in %s.", g:xolox#easytags#version, starttime)
  endif
endfunction

function! s:cache_tagged_files_in(fname, ftime, entries, context) " {{{3
  for entry in a:entries
    let filename = s:canonicalize(entry[1], a:context)
    if filename != ''
      let s:tagged_files[filename] = 1
    endif
  endfor
  let s:known_tagfiles[a:fname] = a:ftime
endfunction

function! xolox#easytags#get_tagsfile() " {{{2
  let tagsfile = ''
  " Look for a suitable project specific tags file?
  let dynamic_files = xolox#misc#option#get('easytags_dynamic_files', 0)
  if dynamic_files == 1
    let tagsfile = get(tagfiles(), 0, '')
  elseif dynamic_files == 2
    let tagsfile = xolox#misc#option#eval_tags(&tags, 1)
    let directory = fnamemodify(tagsfile, ':h')
    if filewritable(directory) != 2
      " If the directory of the dynamic tags file is not writable, we fall
      " back to a file type specific tags file or the global tags file.
      call xolox#misc#msg#warn("easytags.vim %s: Dynamic tags files enabled but %s not writable so falling back.", g:xolox#easytags#version, directory)
      let tagsfile = ''
    endif
  endif
  " Check if a file type specific tags file is useful?
  let applicable_filetypes = xolox#easytags#select_supported_filetypes(&ft)
  if empty(tagsfile) && !empty(g:easytags_by_filetype) && !empty(applicable_filetypes)
    let directory = xolox#misc#path#absolute(g:easytags_by_filetype)
    let tagsfile = xolox#misc#path#merge(directory, applicable_filetypes[0])
  endif
  " Default to the global tags file?
  if empty(tagsfile)
    let tagsfile = expand(xolox#misc#option#get('easytags_file'))
  endif
  " If the tags file exists, make sure it is writable!
  if filereadable(tagsfile) && filewritable(tagsfile) != 1
    let message = "The tags file %s isn't writable!"
    throw printf(message, fnamemodify(tagsfile, ':~'))
  endif
  return tagsfile
endfunction

" Public API for definition of file type specific dynamic syntax highlighting. {{{1

function! xolox#easytags#define_tagkind(object) " {{{2
  if !has_key(a:object, 'pattern_prefix')
    let a:object.pattern_prefix = '\C\<'
  endif
  if !has_key(a:object, 'pattern_suffix')
    let a:object.pattern_suffix = '\>'
  endif
  if !has_key(s:tagkinds, a:object.filetype)
    let s:tagkinds[a:object.filetype] = []
  endif
  call add(s:tagkinds[a:object.filetype], a:object)
endfunction

function! xolox#easytags#map_filetypes(vim_ft, ctags_ft) " {{{2
  call add(s:vim_filetypes, a:vim_ft)
  call add(s:ctags_filetypes, a:ctags_ft)
endfunction

function! xolox#easytags#alias_filetypes(...) " {{{2
  " TODO Simplify alias handling, this much complexity really isn't needed!
  for type in a:000
    let s:canonical_aliases[type] = a:1
    if !has_key(s:aliases, type)
      let s:aliases[type] = {}
    endif
  endfor
  for i in range(a:0)
    for j in range(a:0)
      let vimft1 = a:000[i]
      let ctagsft1 = xolox#easytags#to_ctags_ft(vimft1)
      let vimft2 = a:000[j]
      let ctagsft2 = xolox#easytags#to_ctags_ft(vimft2)
      if !has_key(s:aliases[vimft1], ctagsft2)
        let s:aliases[vimft1][ctagsft2] = 1
      endif
      if !has_key(s:aliases[vimft2], ctagsft1)
        let s:aliases[vimft2][ctagsft1] = 1
      endif
    endfor
  endfor
endfunction

function! xolox#easytags#to_vim_ft(ctags_ft) " {{{2
  let type = tolower(a:ctags_ft)
  let index = index(s:ctags_filetypes, type)
  return index >= 0 ? s:vim_filetypes[index] : type
endfunction

function! xolox#easytags#to_ctags_ft(vim_ft) " {{{2
  let type = tolower(a:vim_ft)
  let index = index(s:vim_filetypes, type)
  return index >= 0 ? s:ctags_filetypes[index] : type
endfunction

" Handling of asynchronous (background) execution. {{{1

function! xolox#easytags#update_remote(context) " {{{2
  " This is phase #2 which is executed by phase #1. We are running in an
  " asynchronous background process, so any errors here will be hidden from
  " the view of the user...
  try
    let &verbose = a:context['verbose']
    let a:context['tags_written'] = s:update_phase_2(a:context)
    if has_key(a:context, 'servername')
      call xolox#misc#msg#info("easytags.vim %s: Notifying remote Vim of successful tag update ..", g:xolox#easytags#version)
      if &verbose >= 1
        let a:context['messages'] = g:xolox_messages
      endif
      call remote_expr(a:context.servername, printf('xolox#easytags#remote_callback(%s)', string(a:context)))
    else
      call xolox#misc#msg#info("easytags.vim %s: Cannot notify remote Vim of our success!", g:xolox#easytags#version)
    endif
  catch
    if has_key(a:context, 'servername')
      call xolox#misc#msg#info("easytags.vim %s: Notifying remote Vim of failed tag update ..", g:xolox#easytags#version)
      let a:context['exception'] = v:exception
      let a:context['throwpoint'] = v:throwpoint
      call remote_expr(a:context.servername, printf('xolox#easytags#remote_callback(%s)', string(a:context)))
    else
      call xolox#misc#msg#warn("easytags.vim %s: Cannot notify remote Vim of failed tag update!", g:xolox#easytags#version)
    endif
  finally
    quit
  endtry
endfunction

function! xolox#easytags#remote_callback(context) " {{{2
  " This is phase #3 which is executed by phase #2. We are now back in the
  " user's Vim editing session through the wonders of server/client
  " communication :-).
  if has_key(a:context, 'exception')
    call xolox#misc#msg#warn("easytags.vim %s: Asynchronous tag update failed: %s (at %s)", g:xolox#easytags#version, a:context['exception'], a:context['throwpoint'])
  else
    " When :UpdateTags was executed manually we'll refresh the dynamic
    " syntax highlighting so that new tags are immediately visible.
    if !a:context['silent'] && xolox#misc#option#get('easytags_auto_highlight', 1)
      HighlightTags
    endif
    " Relay messages reported in the hidden Vim process?
    if a:context['verbose'] >= 1
      for message in a:context['messages']
        call xolox#misc#msg#info("easytags.vim %s: Relaying message from other side: %s", g:xolox#easytags#version, message)
      endfor
    endif
    " Let the user know what happened.
    let msg = "easytags.vim %s: Finished asynchronous tag update in %s (wrote %i tags to %s)."
    call xolox#misc#timer#force(msg,
          \ g:xolox#easytags#version,
          \ a:context['starttime'],
          \ a:context['tags_written'],
          \ fnamemodify(a:context['tagsfile'], ':~'))
  endif
endfunction

" Miscellaneous script-local functions. {{{1

function! s:create_context(values) " {{{2

  " Save the current verbosity level in the context.
  let a:values['verbose'] = &verbose

  " When updating tags asynchronously, the user's vimrc script is not loaded
  " to improve performance and avoid side effects. However this means we have
  " to pass the location of the file type specific tags files explicitly
  " through the context.
  if !has_key(a:values, 'by_filetype')
    let a:values['by_filetype'] = g:easytags_by_filetype
  endif

  " If the user's Vim session has a server name set, we save it in the context
  " so that the Vim running asynchronously can report its results to the
  " user's Vim session.
  if !empty(v:servername)
    let a:values['servername'] = v:servername
  endif

  " The context is used to keep a dictionary with previously canonicalized
  " pathnames to avoid making library calls to ask questions that we already
  " know the answers to.
  if !has_key(a:values, 'cache')
    let a:values['cache'] = {}
  endif

  return a:values

endfunction

function! s:resolve(filename) " {{{2
  if xolox#misc#option#get('easytags_resolve_links', 0)
    return resolve(a:filename)
  else
    return a:filename
  endif
endfunction

function! s:canonicalize(filename, context) " {{{2
  if a:filename != ''
    if has_key(a:context.cache, a:filename)
      return a:context.cache[a:filename]
    else
      let canonical = s:resolve(fnamemodify(a:filename, ':p'))
      let a:context.cache[a:filename] = canonical
      return canonical
    endif
  endif
  return ''
endfunction

" Built-in file type & tag kind definitions. {{{1

" Don't bother redefining everything below when this script is sourced again.
if exists('s:tagkinds')
  finish
endif

let s:tagkinds = {}

" Define the built-in Vim <=> Ctags file-type mappings.
let s:vim_filetypes = []
let s:ctags_filetypes = []
call xolox#easytags#map_filetypes('cpp', 'c++')
call xolox#easytags#map_filetypes('cs', 'c#')
call xolox#easytags#map_filetypes(exists('g:filetype_asp') ? g:filetype_asp : 'aspvbs', 'asp')

" Define the Vim file-types that are aliased by default.
let s:aliases = {}
let s:canonical_aliases = {}
call xolox#easytags#alias_filetypes('c', 'cpp', 'objc', 'objcpp')
call xolox#easytags#alias_filetypes('html', 'htmldjango')

" Enable line continuation.
let s:cpo_save = &cpo
set cpo&vim

" Lua. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'lua',
      \ 'hlgroup': 'luaFunc',
      \ 'tagkinds': 'f'})

" C. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'c',
      \ 'hlgroup': 'cType',
      \ 'tagkinds': '[cgstu]'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'c',
      \ 'hlgroup': 'cEnum',
      \ 'tagkinds': 'e'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'c',
      \ 'hlgroup': 'cPreProc',
      \ 'tagkinds': 'd'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'c',
      \ 'hlgroup': 'cFunction',
      \ 'tagkinds': '[fp]'})

highlight def link cEnum Identifier
highlight def link cFunction Function

if xolox#misc#option#get('easytags_include_members', 0)
  call xolox#easytags#define_tagkind({
        \ 'filetype': 'c',
        \ 'hlgroup': 'cMember',
        \ 'tagkinds': 'm'})
 highlight def link cMember Identifier
endif

" PHP. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'php',
      \ 'hlgroup': 'phpFunctions',
      \ 'tagkinds': 'f',
      \ 'pattern_suffix': '(\@='})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'php',
      \ 'hlgroup': 'phpClasses',
      \ 'tagkinds': 'c'})

" Vim script. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'vim',
      \ 'hlgroup': 'vimAutoGroup',
      \ 'tagkinds': 'a'})

highlight def link vimAutoGroup vimAutoEvent

call xolox#easytags#define_tagkind({
      \ 'filetype': 'vim',
      \ 'hlgroup': 'vimCommand',
      \ 'tagkinds': 'c',
      \ 'pattern_prefix': '\(\(^\|\s\):\?\)\@<=',
      \ 'pattern_suffix': '\(!\?\(\s\|$\)\)\@='})

" Exuberant Ctags doesn't mark script local functions in Vim scripts as
" "static". When your tags file contains search patterns this plug-in can use
" those search patterns to check which Vim script functions are defined
" globally and which script local.

call xolox#easytags#define_tagkind({
      \ 'filetype': 'vim',
      \ 'hlgroup': 'vimFuncName',
      \ 'vim_filter': 'v:val.kind ==# "f" && get(v:val, "cmd", "") !~? ''<sid>\w\|\<s:\w''',
      \ 'pattern_prefix': '\C\%(\<s:\|<[sS][iI][dD]>\)\@<!\<'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'vim',
      \ 'hlgroup': 'vimScriptFuncName',
      \ 'vim_filter': 'v:val.kind ==# "f" && get(v:val, "cmd", "") =~? ''<sid>\w\|\<s:\w''',
      \ 'pattern_prefix': '\C\%(\<s:\|<[sS][iI][dD]>\)'})

highlight def link vimScriptFuncName vimFuncName

" Python. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'python',
      \ 'hlgroup': 'pythonFunction',
      \ 'tagkinds': 'f',
      \ 'pattern_prefix': '\%(\<def\s\+\)\@<!\<'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'python',
      \ 'hlgroup': 'pythonMethod',
      \ 'tagkinds': 'm',
      \ 'pattern_prefix': '\.\@<='})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'python',
      \ 'hlgroup': 'pythonClass',
      \ 'tagkinds': 'c'})

highlight def link pythonMethodTag pythonFunction
highlight def link pythonClassTag pythonFunction

" Java. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'java',
      \ 'hlgroup': 'javaClass',
      \ 'tagkinds': 'c'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'java',
      \ 'hlgroup': 'javaMethod',
      \ 'tagkinds': 'm'})

highlight def link javaClass Identifier
highlight def link javaMethod Function

" C#. {{{2

" TODO C# name spaces, interface names, enumeration member names, structure names?

call xolox#easytags#define_tagkind({
      \ 'filetype': 'cs',
      \ 'hlgroup': 'csClassOrStruct',
      \ 'tagkinds': 'c'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'cs',
      \ 'hlgroup': 'csMethod',
      \ 'tagkinds': '[ms]'})

highlight def link csClassOrStruct Identifier
highlight def link csMethod Function

" Ruby. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'ruby',
      \ 'hlgroup': 'rubyModuleName',
      \ 'tagkinds': 'm'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'ruby',
      \ 'hlgroup': 'rubyClassName',
      \ 'tagkinds': 'c'})

call xolox#easytags#define_tagkind({
      \ 'filetype': 'ruby',
      \ 'hlgroup': 'rubyMethodName',
      \ 'tagkinds': '[fF]'})

highlight def link rubyModuleName Type
highlight def link rubyClassName Type
highlight def link rubyMethodName Function

" Awk. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'awk',
      \ 'hlgroup': 'awkFunctionTag',
      \ 'tagkinds': 'f'})

highlight def link awkFunctionTag Function

" Shell. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'sh',
      \ 'hlgroup': 'shFunctionTag',
      \ 'tagkinds': 'f',
      \ 'pattern_suffix': '\(\w\|\s*()\)\@!'})

highlight def link shFunctionTag Operator

" Tcl. {{{2

call xolox#easytags#define_tagkind({
      \ 'filetype': 'tcl',
      \ 'hlgroup': 'tclCommandTag',
      \ 'tagkinds': 'p'})

highlight def link tclCommandTag Operator

" }}}

" Restore "cpoptions".
let &cpo = s:cpo_save
unlet s:cpo_save

" vim: ts=2 sw=2 et
