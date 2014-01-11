#!/usr/bin/perl
use strict;
use Getopt::Long;
use File::chmod;

my $debug = 0;

sub cmd{
    my $cmd = shift;
    if($debug){
        print ">>$cmd\n";
    }
    my $out = `$cmd`;
    return $out;
}

sub write_file{
    my ($content,$file) = @_;
    my $fd;
    open $fd,'>',$file or die("ERROR: open $file failed.\n");
    syswrite $fd,$content or die("ERROR: write to $file failed.\n");
    close $fd;
}

sub cfg{
    my $file = shift;
    my (%cfg,$lasthost,@dirs);
    my $lines = cmd("cat $file");
    $lasthost = 'common';
    for my $line(split /\n/,$lines){
        next if($line =~ /^\s*$|^\s*#/);
        if($line =~ /\[(\S+)\]/){
            $lasthost = $1;
            $cfg{$lasthost} = [];
        }elsif($line =~ /(\S+)/){
            my $dir = $1;
            if($dir !~ /^\//){
                die("ERROR: Directory or file $dir must be absolute path.\n");
            }
            push @{$cfg{$lasthost}},$dir;
        }
    }

    if($debug){
        for my $host (sort keys %cfg){
            print "[$host]\n";
            for my $dir(sort @{$cfg{$host}}){
                print "$dir\n";
            }
        }
    }
    return \%cfg;
}

sub do_pull{
    my ($cfg) = @_;
    for my $host (sort keys %$cfg){
        print("Pulling from $host\n");
        if(!-d "config/$host"){
            cmd("mkdir -p config/$host");
            cmd("cd config/$host;git init ");
        }else{
            cmd("cd config/$host;git checkout master 2>/dev/null");
        }
        cmd("cd config/$host/;ls|xargs rm -rf");
        for my $dir(sort @{$cfg->{$host}}){
            print("\t$dir\n");
            cmd("ssh $host 'tar -C / -cvf /tmp/tmp.tar $dir 2>/dev/null'");
            cmd("scp $host:/tmp/tmp.tar /tmp");
            cmd("tar -C config/$host -xvf /tmp/tmp.tar");
        }
        metabits_save($host);
        my $meta = metabits_file_to_struct("config/$host/meta.data");
        my $str = metabits_struct_to_string($meta);
        cmd("cd config/$host;git add *");
        my $diff = cmd("cd config/$host;git status");
        if($diff !~ /nothing to commit/){
            print "$diff\n";
            cmd("cd config/$host;git commit -a -m '$diff'");
        }
        write_file($str,"config/$host/meta.data1");
    }
}

sub do_push{
    my ($cfg,$force) = @_;
    for my $host (sort keys %$cfg){
        print("Pushing to $host\n");
        if(!-d "config/$host"){
            die("ERROR: config/$host directory does not exist.\n");
        }
        for my $dir(sort @{$cfg->{$host}}){
            print("\t$dir\n");
            if(! -e "config/$host/$dir"){
                die("ERROR: config/$host/$dir directory or file does not exist.\n");
            }
            if(!$force){
                metabits_check($host);
            }
            cmd("cd config/$host;tar -cvf /tmp/tmp.tar .$dir 2>/dev/null");
            cmd("scp /tmp/tmp.tar $host:/tmp");
            cmd("ssh $host 'rm -rf $dir'");
            cmd("ssh $host 'tar -C / -xvf /tmp/tmp.tar'");
        }
    }
}

sub metabits_save{
    my ($host) = shift;
    my $lines = metabits_string_from_ls($host);
    my $meta = metabits_string_to_struct($lines);
    $lines = metabits_struct_to_string($meta);
    write_file($lines,"config/$host/meta.data");
}

# check if meta.data match the work tree
# two possible reasons if it does not match
# 1, current branch is not master.
# 2, meta bits changed by somebody.
sub metabits_check{
    my ($host) = shift;
    my $lines = metabits_string_from_ls($host);
    my $meta1 = metabits_string_to_struct($lines);
    my $meta2 = metabits_file_to_struct("config/$host/meta.data");
    for my $f(keys %$meta1){
        if($meta2->{$f}){
            my $permission1 = $meta1->{$f}{permission};
            my $user1 = $meta1->{$f}{user};
            my $group1 = $meta1->{$f}{group};
            my $name1 = $meta1->{$f}{name};
            my $linkto1 = $meta1->{$f}{linkto};

            my $permission2 = $meta2->{$f}{permission};
            my $user2 = $meta2->{$f}{user};
            my $group2 = $meta2->{$f}{group};
            my $name2 = $meta2->{$f}{name};
            my $linkto2 = $meta2->{$f}{linkto};
            if($permission1 ne $permission2 ||
                $user1 ne $user2||
                $group1 ne $group2|| 
                $name1 ne $name2|| 
                $linkto1 ne $linkto2){
                die("WARNING: $f meta bits changed. use --force if it is correct\n");
            }
        }
    }
}

sub metabits_string_from_ls{
    my ($host) = @_;
    my $lines= cmd("cd config/$host;ls -lnaR --time-style='+%:z %s'");
    return $lines;
}

sub metabits_string_to_struct{
    my ($meta_lines) = @_;
    my (%meta,$d);
    for my $line(split /\n/,$meta_lines){
        next if($line =~ /^total|^\s*$| \.$| \.\.$/);
        if($line =~ /^(\..*):$/){
            $d = $1;
            if($d =~ /\/\.git\/|\/\.git$/){
                $d = '';
            }
        }else{
            next if(!$d);
            my @metas = split /\s+/,$line,8;
            my $name = $metas[7];
            next if($name eq '.git');
            my $linkto = '';
            if($name =~ /->/){
                ($name,$linkto) = split /->/,$name;
            }
            my $f = $d."/".$name;
            $f =~ s/^\.//;
            $meta{$f}{permission} = $metas[0];
            $meta{$f}{user} = $metas[2];
            $meta{$f}{group} = $metas[3];
            $meta{$f}{name} = $name;
            $meta{$f}{linkto} = $linkto;
        }
    }
    return \%meta;
}

sub metabits_struct_to_string{
    my ($meta) = @_;
    my @lines;
    for my $name (sort keys %$meta){
        my $m= $meta->{$name};
        my $line = "$name|$m->{permission}|$m->{user}|$m->{group}|$m->{name}";
        if($m->{linkto}){
            $line = "$line|$m->{linkto}";
        }
        push @lines,$line;
    }
    return join("\n",@lines)."\n";
}

sub metabits_file_to_struct{
    my ($file) = @_;
    my %meta;
    my $lines = cmd("cat $file");
    for my $line(split /\n/,$lines){
        my @fields = split /\|/,$line;
        if($#fields >= 4){
            my $f= $fields[0];
            my $linkto = '';
            $meta{$f}{permission} = $fields[1];
            $meta{$f}{user} = $fields[2];
            $meta{$f}{group} = $fields[3];
            $meta{$f}{name} = $fields[4];
            if($#fields == 5){
                $linkto = $fields[5];
            }
            $meta{$f}{linkto} = $linkto;
        }
    }
    return \%meta;
}

sub prompt{
    print "Usge:$ARGV[0] [--config config-file] [--push] [--force]\n".
            "\tDefault configuration file is config.list\n".
            "\tDefault action is pull if --push is not specified\n".
            "\t--force will not check meta bits\n";
}

sub main{
    my ($config,$push,$force,$help,$cfg);
    GetOptions('config=s' => \$config, 'push' => \$push, 'force' => \$force, 'debug' => \$debug, 'help' => \$help);
    if($help){
        prompt();
        exit;
    }
    $config ||='config.list';
    if(!-f $config){
        die("ERROR: File $config does not exist.\n");
    }

    $cfg = cfg($config);
    if($push){
        do_push($cfg,$force);
    }else{
        do_pull($cfg);
    }
}

main();
