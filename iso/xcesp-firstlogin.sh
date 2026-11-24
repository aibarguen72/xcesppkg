# /etc/profile.d/xcesp-firstlogin.sh — XCESP installer: offer the first
# setup (management address, licence information) on the first interactive
# login of an administrator, until it has been completed once.
if [ -f /var/lib/xcesp/firstboot-pending ] && [ -t 0 ] && [ -t 1 ]; then
    case " $(id -nG 2>/dev/null) " in
        *" sudo "*|*" root "*)
            echo ""
            echo "XCESP: first setup not done yet (management address, licences)."
            printf "Run it now? [Y/n] "
            read -r _xcesp_ans
            case "$_xcesp_ans" in
                n|N|no|NO) echo "Run it later with: sudo xcesp-setup" ;;
                *) sudo /usr/sbin/xcesp-setup ;;
            esac
            unset _xcesp_ans
            ;;
    esac
fi
