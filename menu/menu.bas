 set romsize 48k
 displaymode 320A
 set zoneheight 8
 set screenheight 192
 
 BACKGRND=$00
 
 incgraphic gfx/menufont.png 320A
 
 P0C1=$0F : P0C2=$3F : P0C3=$6F
 P1C1=$0F : P1C2=$1F : P1C3=$4F
 
 characterset menufont
 alphachars ASCII
 
 ;
 ; Variables - using longer names to avoid conflicts
 ;
 dim game_count = a
 dim selected_game = b
 dim joy_delay = c
 dim temp_y = d
 dim flash_count = e
 dim status_temp = f
 
 ;
 ; FPGA trigger address - just accessing this address triggers FPGA detection
 ; Located in 7800basic user RAM space ($2200-$27FF)
 ;
 dim fpga_trigger = $0458
 
 ;
 ; Initialize variables
 ;
 game_count = 5  
 selected_game = 0
 joy_delay = 0
 
 ;
 ; Draw initial screen once and save it
 ;
 clearscreen
 gosub draw_title
 gosub draw_game_list
 savescreen
 
main_loop
 ;
 ; Restore background, then draw dynamic elements
 ;
 restorescreen
 gosub draw_cursor
 
 ;
 ; Countdown input delay
 ;
 if joy_delay > 0 then joy_delay = joy_delay - 1
 
 ;
 ; Check for joystick input only when not delayed
 ;
 if joy_delay = 0 then gosub check_input
 
 drawscreen
 goto main_loop

draw_title
 ;
 ; Draw title and instructions
 ;
 plotchars 'GAME LOADER' 0 60 0
 plotchars 'SELECT A GAME' 1 60 2
 return

draw_game_list
 ;
 ; Display available games
 ;
 plotchars 'ASTRO WING'       0 10 4
 plotchars 'DONKEY KONG'       0 10 6
 plotchars 'GALAGA'           0 10 8
 plotchars 'MS PAC-MAN'       0 10 10
 plotchars 'DEFENDER'         0 10 12
 plotchars $7F00 1 10 13 13
 plotchars $7F10 1 90 13 11
 plotchars $7F20 1 10 14 13
 plotchars $7F30 1 90 14 13
 return


draw_cursor
 ;
 ; Clear all cursor positions first
 ;
 plotchars ' ' 0 0 4
 plotchars ' ' 0 0 6
 plotchars ' ' 0 0 8
 plotchars ' ' 0 0 10
 plotchars ' ' 0 0 12
 plotchars ' ' 0 0 14
 plotchars ' ' 0 0 15
 plotchars ' ' 0 0 16
 
 ;
 ; Calculate and draw cursor at current selection
 ;
 temp_y = selected_game * 2 + 4
 plotchars '>' 0 0 temp_y
 return

check_input
 ;
 ; Simple joystick check - delay prevents rapid repeats
 ;
 if joy0up then selected_game = selected_game - 1 : joy_delay = 15
 if joy0down then selected_game = selected_game + 1 : joy_delay = 15
 
 ; Trigger Reload (Right + Fire)
 if joy0fire0 && joy0right then fpga_trigger = 64 : joy_delay = 30 : goto select_game_end
 
 if joy0fire0 then gosub select_game : joy_delay = 15
 
select_game_end
 
 ;
 ; Keep selected_game in bounds
 ;
 if selected_game > 7 then selected_game = 0
 if selected_game > 127 then selected_game = 7
 return

move_up
 ;
 ; This is no longer used but kept for compatibility
 ;
 return

move_down
 ;
 ; This is no longer used but kept for compatibility
 ;
 return

select_game
 ;
 ; Visual feedback: flash background briefly
 ;
 flash_count = 8
flash_loop
 BACKGRND=$22
 drawscreen
 BACKGRND=$00
 drawscreen
 flash_count = flash_count - 1
 if flash_count > 0 then goto flash_loop
 
 ;
 ; Trigger FPGA: write selected game + 128 to $2200
 ; This sets bit 7, allowing FPGA to distinguish from initialization (0).
 ;
 fpga_trigger = selected_game + 128
 
 ;
 ; For now, just loop (later we'll add game loading)
 ;
 return
