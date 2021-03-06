with Zip.Headers;

with Ada.Characters.Handling;
with Ada.Unchecked_Deallocation;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

package body Zip is

   use Interfaces;

   procedure Dispose is new Ada.Unchecked_Deallocation (Dir_node, p_Dir_node);
   procedure Dispose is new Ada.Unchecked_Deallocation (String, p_String);

   package Binary_tree_rebalancing is
      procedure Rebalance (root : in out p_Dir_node);
   end Binary_tree_rebalancing;

   package body Binary_tree_rebalancing is

      -------------------------------------------------------------------
      -- Tree Rebalancing in Optimal Time and Space                    --
      -- QUENTIN F. STOUT and BETTE L. WARREN                          --
      -- Communications of the ACM September 1986 Volume 29 Number 9   --
      -------------------------------------------------------------------
      -- http://www.eecs.umich.edu/~qstout/pap/CACM86.pdf
      --
      -- Translated by (New) P2Ada v. 15 - Nov - 2006

      procedure Tree_to_vine (root : p_Dir_node; size : out Integer) is
         --  transform the tree with pseudo - root
         --   "root^" into a vine with pseudo - root
         --   node "root^", and store the number of
         --   nodes in "size"

         vine_tail, remainder, temp : p_Dir_node;

      begin
         vine_tail := root;
         remainder := vine_tail.all.right;
         size := 0;
         while remainder /= null loop
            if remainder.all.left = null then
               --  move vine - tail down one:
               vine_tail := remainder;
               remainder := remainder.all.right;
               size := size + 1;
            else
               --  rotate:
               temp := remainder.all.left;
               remainder.all.left := temp.all.right;
               temp.all.right := remainder;
               remainder := temp;
               vine_tail.all.right := temp;
            end if;
         end loop;
      end Tree_to_vine;

      procedure Vine_to_tree (root : p_Dir_node; size_given : Integer) is
         --  convert the vine with "size" nodes and pseudo - root
         --  node "root^" into a balanced tree
         leaf_count : Integer;
         size  : Integer := size_given;

         procedure Compression (Dir_Root : p_Dir_node; count : Integer) is
            --  compress "count" spine nodes in the tree with pseudo - root "root^"
            scanner, child : p_Dir_node;
         begin
            scanner := Dir_Root;
            for i in 1 .. count loop
               child := scanner.all.right;
               scanner.all.right := child.all.right;
               scanner := scanner.all.right;
               child.all.right := scanner.all.left;
               scanner.all.left := child;
            end loop;
         end Compression;

         -- Returns n - 2 ** Integer (Float'Floor (log (Float (n)) / log (2.0)))
         -- without Float - Point calculation and rounding errors with too short floats
         function Remove_leading_binary_1 (n : Integer) return Integer is
            x : Integer := 2**16; -- supposed maximum
         begin
            if n < 1 then
               return n;
            end if;
            while n mod x = n loop
               x := x / 2;
            end loop;
            return n mod x;
         end Remove_leading_binary_1;

      begin --  Vine_to_tree
         leaf_count := Remove_leading_binary_1 (size + 1);
         Compression (root, leaf_count); -- create deepest leaves
         -- use Perfect_leaves instead for a perfectly balanced tree
         size := size - leaf_count;
         while size > 1 loop
            Compression (root, size / 2);
            size := size / 2;
         end loop;
      end Vine_to_tree;

      procedure Rebalance (root : in out p_Dir_node) is
         --  Rebalance the binary search tree with root "root.all",
         --  with the result also rooted at "root.all".
         --  Uses the Tree_to_vine and Vine_to_tree procedures.
         pseudo_root : p_Dir_node;
         size : Integer;
      begin
         pseudo_root := new Dir_node (name_len => 0);
         pseudo_root.all.right := root;
         Tree_to_vine (pseudo_root, size);
         Vine_to_tree (pseudo_root, size);
         root := pseudo_root.all.right;
         Dispose (pseudo_root);
      end Rebalance;

   end Binary_tree_rebalancing;

   -- 19 - Jun - 2001 : Enhanced file name identification
   --              a) when case insensitive  - > all UPPER (current)
   --              b) '\' and '/' identified - > all '/'   (new)

   function Normalize (s : String; case_sensitive : Boolean) return String is
      sn : String (s'Range);
   begin
      if case_sensitive then
         sn := s;
      else
         sn := Ada.Characters.Handling.To_Upper (s);
      end if;
      for i in sn'Range loop
         if sn (i) = '\' then
            sn (i) := '/';
         end if;
      end loop;
      return sn;
   end Normalize;

   -------------------------------------------------------------
   -- Load Zip_info from a stream containing the .zip archive --
   -------------------------------------------------------------

   procedure Load (info            : out Zip_info;
                   from            :     Zip_Streams.Zipstream_Class;
                   case_sensitive  :     Boolean := False) is

      procedure Insert (dico_name         :        String; -- UPPER if case - insensitive search
                        file_name         :        String;
                        file_index        :        Ada.Streams.Stream_IO.Positive_Count;
                        comp_size,
                        uncomp_size       :        File_size_type;
                        crc_32            :        Unsigned_32;
                        date_time         :        Time;
                        method            :        PKZip_method;
                        unicode_file_name :        Boolean;
                        node              : in out p_Dir_node) is

      begin
         if node = null then
            node := new Dir_node'
              ((name_len          => file_name'Length,
                left              => null,
                right             => null,
                dico_name         => dico_name,
                file_name         => file_name,
                file_index        => file_index,
                comp_size         => comp_size,
                uncomp_size       => uncomp_size,
                crc_32            => crc_32,
                date_time         => date_time,
                method            => method,
                unicode_file_name => unicode_file_name
               )
              );
         elsif dico_name > node.all.dico_name then
            Insert (dico_name, file_name, file_index, comp_size, uncomp_size, crc_32, date_time, method, unicode_file_name, node.all.right);
         elsif dico_name < node.all.dico_name then
            Insert (dico_name, file_name, file_index, comp_size, uncomp_size, crc_32, date_time, method, unicode_file_name, node.all.left);
         else
            raise Duplicate_name;
         end if;
      end Insert;

      the_end : Zip.Headers.End_of_Central_Dir;
      header  : Zip.Headers.Central_File_Header;
      p       : p_Dir_node := null;
      zip_info_already_loaded : exception;
      main_comment : p_String;
      use Ada.Streams, Ada.Streams.Stream_IO;
   begin -- Load Zip_info
      if info.loaded then
         raise zip_info_already_loaded;
      end if; -- 15 - Apr - 2002
      Zip.Headers.Load (from, the_end);
      -- We take the opportunity to read the main comment, which is right
      -- after the end - of - central - directory block.
      main_comment := new String (1 .. Integer (the_end.main_comment_length));
      String'Read (from, main_comment.all);
      -- Process central directory:
      Zip_Streams.Set_Index (
                             from,
                             Positive (
                               1 +
                                 the_end.offset_shifting + the_end.central_dir_offset
                              )
                            );

      for i in 1 .. the_end.total_entries loop
         Zip.Headers.Read_and_check (from, header);
         declare
            this_name : String (1 .. Natural (header.short_info.filename_length));
         begin
            String'Read (from, this_name);
            -- Skip extra field and entry comment.
            Zip_Streams.Set_Index (
                                   from, Positive (
                                     Ada.Streams.Stream_IO.Count (Zip_Streams.Index (from)) +
                                       Ada.Streams.Stream_IO.Count (
                                         header.short_info.extra_field_length +
                                           header.comment_length
                                        ))
                                  );
            -- Now the whole i_th central directory entry is behind
            Insert (dico_name   => Normalize (this_name, case_sensitive),
                    file_name   => Normalize (this_name, True),
                    file_index  => Ada.Streams.Stream_IO.Count
                      (1 + header.local_header_offset + the_end.offset_shifting),
                    comp_size   => header.short_info.dd.compressed_size,
                    uncomp_size => header.short_info.dd.uncompressed_size,
                    crc_32      => header.short_info.dd.crc_32,
                    date_time   => header.short_info.file_timedate,
                    method      => Method_from_code (header.short_info.zip_type),
                    unicode_file_name =>
                      (header.short_info.bit_flag and
                         Zip.Headers.Language_Encoding_Flag_Bit) /= 0,
                    node        => p);
            -- Since the files are usually well ordered, the tree as inserted
            -- is very unbalanced; we need to rebalance it from time to time
            -- during loading, otherwise the insertion slows down dramatically
            -- for zip files with plenty of files - converges to
            -- O (total_entries ** 2) .. .
            if i mod 256 = 0 then
               Binary_tree_rebalancing.Rebalance (p);
            end if;
         end;
      end loop;
      Binary_tree_rebalancing.Rebalance (p);
      info := (loaded           => True,
               zip_file_name    => new String'("This is a stream, no direct file!"),
               zip_input_stream => from,
               dir_binary_tree  => p,
               total_entries    => Integer (the_end.total_entries),
               zip_file_comment => main_comment
              );
   end Load;

   -----------------------------------------------------------
   -- Load Zip_info from a file containing the .zip archive --
   -----------------------------------------------------------

   procedure Load (info            : out Zip_info;
                   from            :     String; -- Zip file name
                   case_sensitive  :     Boolean := False) is

      use Zip_Streams;

      MyStream    : aliased File_Zipstream;
      StreamFile  : constant Zipstream_Class := MyStream'Unchecked_Access;

   begin
      Set_Name (StreamFile, from);
      begin
         Open (MyStream, Ada.Streams.Stream_IO.In_File);
      exception
         when others =>
            Ada.Exceptions.Raise_Exception
              (Zip_file_open_Error'Identity, "Archive : [" & from & ']');
      end;
      -- Call the stream version of Load ( .. .)
      Load (
            info,
            StreamFile,
            case_sensitive
           );
      Close (MyStream);
      Dispose (info.zip_file_name);
      info.zip_file_name := new String'(from);
      info.zip_input_stream := null; -- forget about the stream!
   end Load;

   function Is_loaded (info : Zip_info) return Boolean is (info.loaded);

   function Zip_name (info : Zip_info) return String is

   begin
      if not info.loaded then
         raise Forgot_to_load_zip_info;
      end if;
      return info.zip_file_name.all;
   end Zip_name;

   function Zip_comment (info : Zip_info) return String is

   begin
      if not info.loaded then
         raise Forgot_to_load_zip_info;
      end if;
      return info.zip_file_comment.all;
   end Zip_comment;

   function Zip_Stream (info : Zip_info) return Zip_Streams.Zipstream_Class is

   begin
      if not info.loaded then
         raise Forgot_to_load_zip_info;
      end if;
      return info.zip_input_stream;
   end Zip_Stream;

   function Entries (info : Zip_info) return Natural is (info.total_entries);

   ------------
   -- Delete --
   ------------

   procedure Delete (info  : in out Zip_info) is

      procedure Delete (p : in out p_Dir_node) is
      begin
         if p /= null then
            Delete (p.all.left);
            Delete (p.all.right);
            Dispose (p);
            p := null;
         end if;
      end Delete;

   begin
      if not info.loaded then
         raise Forgot_to_load_zip_info;
      end if;
      Delete (info.dir_binary_tree);
      Dispose (info.zip_file_name);
      info.loaded := False; -- < -- added 14 - Jan - 2002
   end Delete;

   -- Traverse a whole Zip_info directory in sorted order, giving the
   -- name for each entry to an user - defined "Action" procedure.
   -- Added 29 - Nov - 2002
   procedure Traverse (z : Zip_info) is

      procedure Traverse (p : p_Dir_node) is

      begin
         if p /= null then
            Traverse (p.all.left);
            Action (p.all.file_name);
            Traverse (p.all.right);
         end if;
      end Traverse;

   begin
      Traverse (z.dir_binary_tree);
   end Traverse;

   procedure Traverse_verbose (z : Zip_info) is

      procedure Traverse_verbose_recursive (p : p_Dir_node) is

      begin
         if p /= null then
            Traverse_verbose_recursive (p.all.left);
            Action (p.all.file_name,
                    Positive (p.all.file_index),
                    p.all.comp_size,
                    p.all.uncomp_size,
                    p.all.crc_32,
                    p.all.date_time,
                    p.all.method,
                    p.all.unicode_file_name);
            Traverse_verbose_recursive (p.all.right);
         end if;
      end Traverse_verbose_recursive;

   begin
      Traverse_verbose_recursive (z.dir_binary_tree);
   end Traverse_verbose;

   procedure Tree_stat (z         :     Zip_info;
                        total     : out Natural;
                        max_depth : out Natural;
                        avg_depth : out Float) is

      sum_depth : Natural := 0;

      procedure Traverse_stat_recursive (p : p_Dir_node; depth : Natural) is

      begin
         if p /= null then
            total := total + 1;
            if depth > max_depth then
               max_depth := depth;
            end if;
            sum_depth := sum_depth + depth;
            Traverse_stat_recursive (p.all.left, depth + 1);
            Traverse_stat_recursive (p.all.right, depth + 1);
         end if;
      end Traverse_stat_recursive;

   begin
      total := 0;
      max_depth := 0;
      Traverse_stat_recursive (z.dir_binary_tree, 0);
      if total = 0 then
         avg_depth := 0.0;
      else
         avg_depth := Float (sum_depth) / Float (total);
      end if;
   end Tree_stat;

   -- 13 - May - 2001 : Find_first_offset

   -- For an all - files unzipping of an appended (e.g. self - extracting) archive
   -- (not beginning with ZIP contents), we cannot start with
   -- index 1 in file.
   -- But the offset of first entry in ZIP directory is not valid either,
   -- as this excerpt of appnote.txt states:

   -- "   4)  The entries in the central directory may not necessarily
   --         be in the same order that files appear in the zipfile.    "

   procedure Find_first_offset (file            :     Zip_Streams.Zipstream_Class;
                                file_index      : out Positive) is

      the_end    : Zip.Headers.End_of_Central_Dir;
      header     : Zip.Headers.Central_File_Header;
      min_offset : File_size_type;

      use Ada.Streams.Stream_IO, Zip_Streams;

   begin
      Zip.Headers.Load (file, the_end);
      Set_Index (
                 file, Positive (1 + the_end.offset_shifting + the_end.central_dir_offset)
                );

      min_offset := the_end.central_dir_offset; -- will be lowered

      for i in 1 .. the_end.total_entries loop
         declare
            TempStream  : constant Zip_Streams.Zipstream_Class := file;
         begin
            Zip.Headers.Read_and_check (TempStream, header);
         end;

         Set_Index (file, Index (file) +
                      Positive
                        (header.short_info.filename_length +
                             header.short_info.extra_field_length +
                               header.comment_length));
         -- Now the whole i_th central directory entry is behind

         if header.local_header_offset < min_offset then
            min_offset := header.local_header_offset;
         end if;
      end loop;

      file_index := Positive (1 + min_offset + the_end.offset_shifting);

   end Find_first_offset;

   -- Internal : find offset of a zipped file by reading sequentially the
   -- central directory : - (

   procedure Find_offset (file            :     Zip_Streams.Zipstream_Class;
                          name            :     String;
                          case_sensitive  :     Boolean;
                          file_index      : out Positive;
                          comp_size       : out File_size_type;
                          uncomp_size     : out File_size_type) is

      the_end : Zip.Headers.End_of_Central_Dir;

      header  : Zip.Headers.Central_File_Header;

      use Ada.Streams, Ada.Streams.Stream_IO, Zip_Streams;

   begin
      Zip.Headers.Load (file, the_end);
      Set_Index (file, Positive (1 + the_end.central_dir_offset + the_end.offset_shifting));
      for i in 1 .. the_end.total_entries loop
         declare
            TempStream  : constant Zipstream_Class := file;
         begin
            Zip.Headers.Read_and_check (TempStream, header);
         end;
         declare
            this_name : String (1 .. Natural (header.short_info.filename_length));
         begin
            String'Read (file, this_name);
            Set_Index (file, Index (file) +
                         Natural (Ada.Streams.Stream_IO.Count
                           (header.short_info.extra_field_length +
                                header.comment_length)));
            -- Now the whole i_th central directory entry is behind
            if Normalize (this_name, case_sensitive) =
              Normalize (name, case_sensitive)
            then
               -- Name found in central directory !
               file_index := Positive (1 + header.local_header_offset + the_end.offset_shifting);
               comp_size  := File_size_type (header.short_info.dd.compressed_size);
               uncomp_size := File_size_type (header.short_info.dd.uncompressed_size);
               return;
            end if;
         end;
      end loop;
      raise File_name_not_found;
   end Find_offset;

   -- Internal : find offset of a zipped file using the zip_info tree 8 - )

   procedure Find_offset (info            :     Zip_info;
                          name            :     String;
                          case_sensitive  :     Boolean;
                          file_index      : out Ada.Streams.Stream_IO.Positive_Count;
                          comp_size       : out File_size_type;
                          uncomp_size     : out File_size_type) is

      aux : p_Dir_node := info.dir_binary_tree;
      up_name : String := Normalize (name, case_sensitive);

   begin
      if not info.loaded then
         raise Forgot_to_load_zip_info;
      end if;
      while aux /= null loop
         if up_name > aux.all.dico_name then
            aux := aux.all.right;
         elsif up_name < aux.all.dico_name then
            aux := aux.all.left;
         else  -- file found !
            file_index := aux.all.file_index;
            comp_size  := aux.all.comp_size;
            uncomp_size := aux.all.uncomp_size;
            return;
         end if;
      end loop;
      Ada.Exceptions.Raise_Exception (
                                      File_name_not_found'Identity,
                                      "Archive : [" & info.zip_file_name.all & "], entry : [" & name & ']'
                                     );
   end Find_offset;

   procedure Get_sizes (info            :     Zip_info;
                        name            :     String;
                        case_sensitive  :     Boolean;
                        comp_size       : out File_size_type;
                        uncomp_size     : out File_size_type) is

      dummy_file_index : Ada.Streams.Stream_IO.Positive_Count;

   begin
      Find_offset (info, name, case_sensitive, dummy_file_index, comp_size, uncomp_size);
      pragma Unreferenced (dummy_file_index);
   end Get_sizes;

   -- Workaround for the severe xxx'Read xxx'Write performance
   -- problems in the GNAT and ObjectAda compilers (as in 2009)
   -- This is possible if and only if Byte = Stream_Element and
   -- arrays types are both packed and aligned the same way.
   --
   subtype Size_test_a is Byte_Buffer (1 .. 19);
   subtype Size_test_b is Ada.Streams.Stream_Element_Array (1 .. 19);
   workaround_possible : constant Boolean :=
     Size_test_a'Size = Size_test_b'Size and then
     Size_test_a'Alignment = Size_test_b'Alignment;

   -- BlockRead - general - purpose procedure (nothing really specific
   -- to Zip / UnZip) : reads either the whole buffer from a file, or
   -- if the end of the file lays inbetween, a part of the buffer.

   procedure BlockRead (file          :     Ada.Streams.Stream_IO.File_Type;
                        buffer        : out Byte_Buffer;
                        actually_read : out Natural) is

      use Ada.Streams, Ada.Streams.Stream_IO;

      SE_Buffer    : Stream_Element_Array (1 .. buffer'Length);
      for SE_Buffer'Address use buffer'Address;
      pragma Import (Ada, SE_Buffer);

      Last_Read    : Stream_Element_Offset;

   begin
      if workaround_possible then
         Read (Stream (file).all, SE_Buffer, Last_Read);
         actually_read := Natural (Last_Read);
      else
         if End_Of_File (file) then
            actually_read := 0;
         else
            actually_read :=
              Integer'Min (buffer'Length, Integer (Size (file) - Index (file) + 1));
            Byte_Buffer'Read (
                              Stream (file),
                              buffer (buffer'First .. buffer'First + actually_read - 1)
                             );
         end if;
      end if;
   end BlockRead;

   procedure BlockRead (stream        :     Zip_Streams.Zipstream_Class;
                        buffer        : out Byte_Buffer;
                        actually_read : out Natural) is

      use Ada.Streams, Ada.Streams.Stream_IO, Zip_Streams;

      SE_Buffer    : Stream_Element_Array (1 .. buffer'Length);
      for SE_Buffer'Address use buffer'Address;
      pragma Import (Ada, SE_Buffer);

      Last_Read    : Stream_Element_Offset;

   begin
      if workaround_possible then
         Read (stream.all, SE_Buffer, Last_Read);
         actually_read := Natural (Last_Read);
      else
         if End_Of_Stream (stream) then
            actually_read := 0;
         else
            actually_read := Integer'Min (buffer'Length, Integer (Size (stream) - Index (stream) + 1));
            Byte_Buffer'Read (stream, buffer (buffer'First .. buffer'First + actually_read - 1));
         end if;
      end if;
   end BlockRead;

   procedure BlockRead (stream  :     Zip_Streams.Zipstream_Class;
                        buffer  : out Byte_Buffer) is

      actually_read : Natural;

   begin
      BlockRead (stream, buffer, actually_read);
      if actually_read < buffer'Length then
         raise Ada.IO_Exceptions.End_Error;
      end if;
   end BlockRead;

   procedure BlockWrite (stream  : in out Ada.Streams.Root_Stream_Type'Class;
                         buffer  :        Byte_Buffer) is

      use Ada.Streams;

      SE_Buffer    : Stream_Element_Array (1 .. buffer'Length);
      for SE_Buffer'Address use buffer'Address;
      pragma Import (Ada, SE_Buffer);

   begin
      if workaround_possible then
         Ada.Streams.Write (stream, SE_Buffer);
      else
         Byte_Buffer'Write (stream'Access, buffer);
         -- ^This is 30x to 70x slower on GNAT 2009 !
      end if;
   end BlockWrite;

   function Method_from_code (x : Natural) return PKZip_method is
      -- An enumeration clause might be more elegant, but needs
      -- curiously an Unchecked_Conversion .. . (RM 13.4)

   begin
      case x is
         when  0 => return store;
         when  1 => return shrink;
         when  2 => return reduce_1;
         when  3 => return reduce_2;
         when  4 => return reduce_3;
         when  5 => return reduce_4;
         when  6 => return implode;
         when  7 => return tokenize;
         when  8 => return deflate;
         when  9 => return deflate_e;
         when 12 => return bzip2;
         when 14 => return lzma;
         when 98 => return ppmd;
         when others => return unknown;
      end case;
   end Method_from_code;

   function Method_from_code (x : Interfaces.Unsigned_16) return PKZip_method is
     (Method_from_code (Natural (x)));

   -- This does the same as Ada 2005's Ada.Directories.Exists
   -- Just there as helper for Ada 95 only systems
   --
   function Exists (name : String) return Boolean is

      use Ada.Text_IO, Ada.Strings.Fixed;

      f : File_Type;

   begin
      if Index (name, "*") > 0 then
         return False;
      end if;
      Open (f, In_File, name, Form => Ada.Strings.Unbounded.To_String (Form_For_IO_Open_N_Create));
      Close (f);
      return True;

   exception
      when Name_Error =>
         return False; -- The file cannot exist !
      when Use_Error =>
         return True;  -- The file exist and is already opened !
   end Exists;

   procedure Put_Multi_Line (
                             out_file  :        Ada.Text_IO.File_Type;
                             text      :        String
                            )
   is
      last_char : Character := ' ';
      c : Character;
   begin
      for i in text'Range loop
         c := text (i);
         case c is
            when ASCII.CR =>
               Ada.Text_IO.New_Line (out_file);
            when ASCII.LF =>
               if last_char /= ASCII.CR then
                  Ada.Text_IO.New_Line (out_file);
               end if;
            when others =>
               Ada.Text_IO.Put (out_file, c);
         end case;
         last_char := c;
      end loop;
   end Put_Multi_Line;

   procedure Write_as_text (out_file  :        Ada.Text_IO.File_Type;
                            buffer    :        Byte_Buffer;
                            last_char : in out Character) is -- track line - ending characters across writes

      c : Character;

   begin
      for i in buffer'Range loop
         c := Character'Val (buffer (i));
         case c is
         when ASCII.CR =>
            Ada.Text_IO.New_Line (out_file);
         when ASCII.LF =>
            if last_char /= ASCII.CR then
               Ada.Text_IO.New_Line (out_file);
            end if;
         when others =>
            Ada.Text_IO.Put (out_file, c);
         end case;
         last_char := c;
      end loop;
   end Write_as_text;

end Zip;
